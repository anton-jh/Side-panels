// Moza pot test - PC side.
//
// Reads pot values (0..16368, one per line) from the Arduino over serial and steers the
// wheel base with a DirectInput "spring" force-feedback effect. The spring's centre
// (Offset) is moved to where the pot says, and the base's own firmware pulls the wheel there.
//
// Spring Offset is -10000..+10000 = the full axis range, i.e. +-half of the rotation
// angle set in Moza Pit House. "Range %" limits how far of that the pot can command.
//
// Knobs:
//  - Spring:     how hard the wheel is pulled to the target.
//  - Damping:    a DirectInput "damper" effect (force against wheel speed), adds to Pit House's.
//  - Max speed:  limits how fast the target may move, so fast flicks become ramps (less overshoot).
//  - Smoothing:  low-pass on the target, so it moves continuously instead of in steps.
//  - Deadband:   no spring force within this distance of the target (stops buzzing/hunting there).
//
// The FFB updates run on their own thread at ~250 Hz; the UI only shows values and reads settings.

using System.Diagnostics;
using System.IO.Ports;
using System.Runtime.InteropServices;
using SharpDX.DirectInput;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MainForm());
    }
}

internal sealed class MainForm : Form
{
    private const int PotMax = 16368;    // must match the Arduino sketch (16 x 1023)
    private const int UpdateSleepMs = 4; // FFB thread period, ~250 Hz

    private readonly ComboBox _portBox = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 120 };
    private readonly Button _startButton = new() { Text = "Start", Width = 80 };
    private readonly NumericUpDown _rangeBox = new() { Minimum = 1, Maximum = 100, Value = 25, Width = 60 };
    private readonly NumericUpDown _strengthBox = new() { Minimum = 0, Maximum = 10000, Value = 4000, Increment = 500, Width = 70 };
    private readonly NumericUpDown _dampingBox = new() { Minimum = 0, Maximum = 10000, Value = 3000, Increment = 500, Width = 70 };
    private readonly NumericUpDown _speedBox = new() { Minimum = 0, Maximum = 5000, Value = 150, Increment = 25, Width = 70 };
    private readonly NumericUpDown _smoothBox = new() { Minimum = 0, Maximum = 500, Value = 40, Increment = 10, Width = 60 };
    private readonly NumericUpDown _deadbandBox = new() { Minimum = 0, Maximum = 1000, Value = 0, Increment = 10, Width = 60 };
    private readonly Label _status = new() { AutoSize = true, Font = new Font(FontFamily.GenericMonospace, 10) };
    private readonly System.Windows.Forms.Timer _uiTimer = new() { Interval = 50 };

    private SerialPort? _serial;
    private DirectInput? _di;
    private Joystick? _joy;
    private Effect? _spring;
    private EffectParameters? _springParams;
    private ConditionSet? _springCondition;
    private Effect? _damper;
    private EffectParameters? _damperParams;
    private ConditionSet? _damperCondition;
    private string _deviceName = "";

    private Thread? _worker;
    private volatile bool _running;

    // Serial thread -> FFB thread.
    private volatile int _pot = -1;      // latest value from the Arduino, -1 = nothing yet

    // UI thread -> FFB thread (copied from the boxes by the UI timer).
    private volatile int _setRange, _setStrength, _setDamping, _setSpeed, _setSmoothMs, _setDeadband;

    // FFB thread -> UI thread.
    private volatile int _shownTarget, _shownOffset;
    private volatile int _shownWheel = -1;
    private volatile string? _error;

    public MainForm()
    {
        Text = "Moza pot test";
        Width = 640;
        Height = 300;

        var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 40, Padding = new Padding(6) };
        top.Controls.Add(MakeLabel("Arduino port:", 3));
        top.Controls.Add(_portBox);
        top.Controls.Add(_startButton);
        top.Controls.Add(MakeLabel("Range %:", 12));
        top.Controls.Add(_rangeBox);

        var second = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 40, Padding = new Padding(6) };
        second.Controls.Add(MakeLabel("Spring:", 3));
        second.Controls.Add(_strengthBox);
        second.Controls.Add(MakeLabel("Damping:", 12));
        second.Controls.Add(_dampingBox);
        second.Controls.Add(MakeLabel("Deadband:", 12));
        second.Controls.Add(_deadbandBox);

        var third = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 40, Padding = new Padding(6) };
        third.Controls.Add(MakeLabel("Max speed %/s (0 = off):", 3));
        third.Controls.Add(_speedBox);
        third.Controls.Add(MakeLabel("Smoothing ms:", 12));
        third.Controls.Add(_smoothBox);

        _status.Location = new Point(12, 130);
        Controls.Add(_status);
        Controls.Add(third);
        Controls.Add(second);
        Controls.Add(top);

        _portBox.Items.AddRange(SerialPort.GetPortNames().OrderBy(p => p).ToArray<object>());
        if (_portBox.Items.Count > 0) _portBox.SelectedIndex = _portBox.Items.Count - 1; // Arduino is usually the newest port

        _startButton.Click += (_, _) => Start();
        _uiTimer.Tick += (_, _) => { PublishSettings(); ShowStatus(); };
        FormClosing += (_, _) => Shutdown();
        _status.Text = "Pick the Arduino's COM port and press Start.\nKeep your hands off the wheel - it will move by itself.";
    }

    private static Label MakeLabel(string text, int leftMargin) =>
        new() { Text = text, AutoSize = true, Margin = new Padding(leftMargin, 7, 3, 0) };

    private void PublishSettings()
    {
        _setRange = (int)_rangeBox.Value;
        _setStrength = (int)_strengthBox.Value;
        _setDamping = (int)_dampingBox.Value;
        _setSpeed = (int)_speedBox.Value;
        _setSmoothMs = (int)_smoothBox.Value;
        _setDeadband = (int)_deadbandBox.Value;
    }

    private void Start()
    {
        if (_portBox.SelectedItem is not string port) { MessageBox.Show("No COM port selected."); return; }

        try
        {
            PublishSettings();
            OpenWheel();
            _serial = new SerialPort(port, 115200) { NewLine = "\n", ReadTimeout = 500 };
            _serial.DataReceived += OnSerialData;
            _serial.Open();
        }
        catch (Exception ex)
        {
            Shutdown();
            MessageBox.Show(ex.Message, "Start failed");
            return;
        }

        _startButton.Enabled = false;
        _portBox.Enabled = false;
        _running = true;
        _worker = new Thread(WorkerLoop) { IsBackground = true, Name = "FFB", Priority = ThreadPriority.AboveNormal };
        _worker.Start();
        _uiTimer.Start();
    }

    private void OpenWheel()
    {
        _di = new DirectInput();
        var devices = _di.GetDevices(DeviceClass.GameControl, DeviceEnumerationFlags.ForceFeedback | DeviceEnumerationFlags.AttachedOnly);
        var dev = devices.FirstOrDefault(d => d.ProductName.Contains("MOZA", StringComparison.OrdinalIgnoreCase))
                  ?? devices.FirstOrDefault()
                  ?? throw new InvalidOperationException("No force-feedback game controller found.");
        _deviceName = dev.ProductName;

        _joy = new Joystick(_di, dev.InstanceGuid);
        // FFB needs exclusive access; Background lets it keep working when this window isn't focused.
        _joy.SetCooperativeLevel(Handle, CooperativeLevel.Exclusive | CooperativeLevel.Background);
        _joy.Properties.AutoCenter = false;
        _joy.Acquire();

        (_spring, _springParams, _springCondition) = CreateConditionEffect(EffectGuid.Spring, _setStrength);
        (_damper, _damperParams, _damperCondition) = CreateConditionEffect(EffectGuid.Damper, _setDamping);
    }

    // Spring and damper are both "condition" effects: same parameter layout, different meaning
    // (spring: force against position error, damper: force against speed).
    private (Effect, EffectParameters, ConditionSet) CreateConditionEffect(Guid type, int coefficient)
    {
        var condition = new ConditionSet
        {
            Conditions = new[]
            {
                new Condition
                {
                    Offset = 0,
                    PositiveCoefficient = coefficient,
                    NegativeCoefficient = coefficient,
                    PositiveSaturation = 10000,
                    NegativeSaturation = 10000,
                    DeadBand = 0,
                },
            },
        };

        var parameters = new EffectParameters
        {
            Duration = -1,                 // INFINITE
            Flags = EffectFlags.Cartesian | EffectFlags.ObjectOffsets,
            Gain = 10000,
            SamplePeriod = 0,
            StartDelay = 0,
            TriggerButton = -1,            // no trigger button
            TriggerRepeatInterval = 0,
            Parameters = condition,
        };
        parameters.SetAxes(new[] { (int)JoystickOffset.X }, new[] { 0 }); // steering = X axis

        var effect = new Effect(_joy!, type, parameters);
        effect.Start();
        return (effect, parameters, condition);
    }

    private void OnSerialData(object sender, SerialDataReceivedEventArgs e)
    {
        try
        {
            while (_serial is { IsOpen: true } s && s.BytesToRead > 0)
            {
                var line = s.ReadLine().Trim();
                if (int.TryParse(line, out var v) && v >= 0 && v <= PotMax) _pot = v;
            }
        }
        catch (TimeoutException) { }        // partial line, the rest comes next time
        catch (InvalidOperationException) { } // port closed while reading
        catch (IOException) { }
    }

    [DllImport("winmm.dll")] private static extern uint timeBeginPeriod(uint ms);
    [DllImport("winmm.dll")] private static extern uint timeEndPeriod(uint ms);

    private void WorkerLoop()
    {
        timeBeginPeriod(1); // lets Thread.Sleep(4) actually sleep ~4 ms instead of ~15.6 ms
        try
        {
            var clock = Stopwatch.StartNew();
            double commanded = 0;   // after the speed limit
            double smoothed = 0;    // after smoothing = what the spring gets
            int lastOffset = int.MinValue, lastStrength = -1, lastDamping = -1, lastDeadband = -1;

            while (_running)
            {
                var dt = clock.Elapsed.TotalSeconds;
                clock.Restart();

                // Where the pot wants the wheel.
                var pot = _pot;
                double target = 0;
                if (pot >= 0)
                {
                    var normalized = (pot - PotMax / 2.0) / (PotMax / 2.0); // -1 .. +1
                    target = normalized * _setRange * 100.0;                // range% of 10000
                }

                // Speed limit: 100 %/s = from centre to full lock in one second.
                var maxStep = _setSpeed * 100.0 * dt;
                commanded = maxStep <= 0 ? target : commanded + Math.Clamp(target - commanded, -maxStep, maxStep);

                // Smoothing: first-order low-pass with time constant Smoothing ms.
                var tau = _setSmoothMs / 1000.0;
                smoothed = tau <= 0 ? commanded : smoothed + (commanded - smoothed) * (1 - Math.Exp(-dt / tau));

                var offset = (int)Math.Round(smoothed);
                var strength = _setStrength;
                var damping = _setDamping;
                var deadband = _setDeadband;

                try
                {
                    if (offset != lastOffset || strength != lastStrength || deadband != lastDeadband)
                    {
                        _springCondition!.Conditions[0].Offset = offset;
                        _springCondition.Conditions[0].PositiveCoefficient = strength;
                        _springCondition.Conditions[0].NegativeCoefficient = strength;
                        _springCondition.Conditions[0].DeadBand = deadband;
                        _spring!.SetParameters(_springParams, EffectParameterFlags.TypeSpecificParameters);
                        lastOffset = offset;
                        lastStrength = strength;
                        lastDeadband = deadband;
                    }

                    if (damping != lastDamping)
                    {
                        _damperCondition!.Conditions[0].PositiveCoefficient = damping;
                        _damperCondition.Conditions[0].NegativeCoefficient = damping;
                        _damper!.SetParameters(_damperParams, EffectParameterFlags.TypeSpecificParameters);
                        lastDamping = damping;
                    }

                    _joy!.Poll();
                    _shownWheel = _joy.GetCurrentState().X; // 0..65535
                    _error = null;
                }
                catch (SharpDX.SharpDXException ex)
                {
                    _error = ex.Message;
                }

                _shownTarget = (int)Math.Round(target);
                _shownOffset = offset;
                Thread.Sleep(UpdateSleepMs);
            }
        }
        finally
        {
            timeEndPeriod(1);
        }
    }

    private void ShowStatus()
    {
        var pot = _pot;
        var wheel = _shownWheel;
        _status.Text =
            $"Device : {_deviceName}\n" +
            $"Pot    : {(pot < 0 ? "(no data yet)" : pot.ToString())}\n" +
            $"Target : {_shownTarget,6}  (-10000..10000)\n" +
            $"Spring : {_shownOffset,6}  (after speed limit + smoothing)\n" +
            $"Wheel X: {(wheel < 0 ? "     ?" : ((wheel - 32767.5) / 3.27675).ToString("0").PadLeft(6))}  (same scale)" +
            (_error is { } err ? $"\nFFB error: {err}" : "");
    }

    private void Shutdown()
    {
        _uiTimer.Stop();
        _running = false;
        _worker?.Join(1000);
        _worker = null;

        try { _serial?.Close(); } catch { }
        _serial?.Dispose();
        _serial = null;

        foreach (var effect in new[] { _spring, _damper })
        {
            try { effect?.Stop(); } catch { }
            effect?.Dispose();
        }
        _spring = null;
        _damper = null;

        try { _joy?.Unacquire(); } catch { }
        _joy?.Dispose();
        _joy = null;

        _di?.Dispose();
        _di = null;
    }
}
