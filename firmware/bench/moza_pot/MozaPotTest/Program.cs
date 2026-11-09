// Moza pot test - PC side.
//
// Reads pot values (0..1023, one per line) from the Arduino over serial and
// makes the wheel follow them, using a plain DirectInput force-feedback
// "spring" effect: the wheel's own firmware pulls the wheel towards the
// spring's centre point, and we just move that centre point around.
// Works with any DirectInput FFB wheel, nothing Moza-specific.
//
// Usage:  MozaPotTest COM5
//         MozaPotTest          (lists serial ports)
// Ctrl+C to stop (the spring is removed and the wheel goes limp).

using System.IO.Ports;
using System.Runtime.InteropServices;
using SharpDX.DirectInput;

// ---- Settings: change these to taste ----------------------------------

// Must match "Steering wheel angle" (max rotation, lock to lock) in Moza Pit House.
const double WheelRotationDeg = 900;

// How far the pot turns the wheel, lock to lock. 180 = pot sweeps -90..+90 degrees.
const double TestRangeDeg = 180;

// Spring stiffness, 0..10000. Start low; the R5 is strong enough to hurt a thumb.
const int SpringStrength = 3000;

// Ramp the spring in over this long at start-up, so the wheel doesn't snap.
const double RampSeconds = 2.0;

// -----------------------------------------------------------------------

if (args.Length < 1)
{
    Console.WriteLine("Usage: MozaPotTest <COM port>");
    Console.WriteLine("Serial ports: " + string.Join(", ", SerialPort.GetPortNames()));
    return 1;
}

// --- Find the wheel ---
var directInput = new DirectInput();
var ffbDevices = directInput.GetDevices(DeviceClass.GameControl,
    DeviceEnumerationFlags.AttachedOnly | DeviceEnumerationFlags.ForceFeedback);

if (ffbDevices.Count == 0)
{
    Console.WriteLine("No force-feedback device found. Is Pit House / the wheel connected?");
    return 1;
}

Console.WriteLine("Force-feedback devices:");
foreach (var d in ffbDevices)
    Console.WriteLine("  " + d.ProductName);

// Prefer something called "Moza", otherwise take the first FFB device.
var wheelInfo = ffbDevices.FirstOrDefault(d => d.ProductName.Contains("moza", StringComparison.OrdinalIgnoreCase))
                ?? ffbDevices[0];
Console.WriteLine("Using: " + wheelInfo.ProductName);

var wheel = new Joystick(directInput, wheelInfo.InstanceGuid);

// DirectInput needs a top-level window handle for exclusive (FFB) access.
// A never-shown window is enough.
IntPtr hiddenWindow = Native.CreateWindowEx(0, "STATIC", "MozaPotTest", 0, 0, 0, 0, 0,
    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
wheel.SetCooperativeLevel(hiddenWindow, CooperativeLevel.Background | CooperativeLevel.Exclusive);
wheel.Properties.AutoCenter = false;
wheel.Acquire();

// The first force-feedback axis is the steering axis.
int steeringAxis = wheel.GetObjects()
    .Where(o => (o.ObjectId.Flags & DeviceObjectTypeFlags.ForceFeedbackActuator) != 0)
    .Select(o => (int)o.ObjectId)
    .First();

// --- Spring effect ---
// Offset: -10000..10000 = full left..full right of the wheel's configured rotation.
EffectParameters SpringParams(int offset, int strength)
{
    var p = new EffectParameters
    {
        Flags = EffectFlags.Cartesian | EffectFlags.ObjectIds,
        Duration = -1,                 // INFINITE
        Gain = 10000,
        SamplePeriod = 0,
        StartDelay = 0,
        TriggerButton = -1,            // no trigger button
        TriggerRepeatInterval = 0,
        Parameters = new ConditionSet
        {
            Conditions = new[]
            {
                new Condition
                {
                    Offset = offset,
                    PositiveCoefficient = strength,
                    NegativeCoefficient = strength,
                    PositiveSaturation = 10000,
                    NegativeSaturation = 10000,
                    DeadBand = 0,
                },
            },
        },
    };
    p.SetAxes(new[] { steeringAxis }, new[] { 0 });
    return p;
}

var spring = new Effect(wheel, EffectGuid.Spring, SpringParams(0, 0));
spring.Start(1, EffectPlayFlags.None);

// --- Serial ---
using var serial = new SerialPort(args[0], 115200) { ReadTimeout = 1000, NewLine = "\n" };
serial.Open();
Console.WriteLine($"Listening on {args[0]}. Ctrl+C to stop.");

bool running = true;
Console.CancelKeyPress += (_, e) => { e.Cancel = true; running = false; };

var startTime = DateTime.Now;
var lastPrint = DateTime.MinValue;

try
{
    while (running)
    {
        string line;
        try { line = serial.ReadLine().Trim(); }
        catch (TimeoutException) { Console.WriteLine("\nNo data from Arduino..."); continue; }

        // The Nano resets when the port opens, so the first line can be junk.
        if (!int.TryParse(line, out int pot) || pot < 0 || pot > 1023)
            continue;

        // Pot 0..1023 -> target angle in degrees (negative = left).
        double targetDeg = (pot / 1023.0 - 0.5) * TestRangeDeg;

        // Angle -> spring offset (-10000..10000 over the full wheel rotation).
        int offset = (int)Math.Clamp(targetDeg / (WheelRotationDeg / 2) * 10000, -10000, 10000);

        double ramp = Math.Min(1.0, (DateTime.Now - startTime).TotalSeconds / RampSeconds);
        int strength = (int)(SpringStrength * ramp);

        spring.SetParameters(SpringParams(offset, strength), EffectParameterFlags.TypeSpecificParameters);

        if ((DateTime.Now - lastPrint).TotalMilliseconds > 100)
        {
            lastPrint = DateTime.Now;
            wheel.Poll();
            int x = wheel.GetCurrentState().X;   // 0..65535
            double actualDeg = (x / 65535.0 - 0.5) * WheelRotationDeg;
            Console.Write($"\rpot {pot,4}   target {targetDeg,7:F1} deg   wheel {actualDeg,7:F1} deg   ");
        }
    }
}
finally
{
    Console.WriteLine("\nStopping.");
    spring.Stop();
    spring.Dispose();
    wheel.Unacquire();
    wheel.Dispose();
    directInput.Dispose();
    Native.DestroyWindow(hiddenWindow);
}

return 0;

static class Native
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateWindowEx(int exStyle, string className, string windowName, int style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [DllImport("user32.dll")]
    public static extern bool DestroyWindow(IntPtr hwnd);
}
