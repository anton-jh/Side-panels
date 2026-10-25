#Requires -Version 7.0
<#
.SYNOPSIS
    Writes AISLER's published design rules into this repo's KiCad projects.

.DESCRIPTION
    Single source of truth for the fab limits. Running this is equivalent to
    typing the numbers into Board Setup by hand, except that it is reviewable,
    diffable and repeatable.

    For each project it writes two things:

      <project>.kicad_dru   the limits KiCad has no Board Setup field for
      <project>.kicad_pro   Board Setup > Design Rules > Constraints, plus the
                            DRC severities, edited in place

    Why both files: Board Setup constraints are absolute floors that never
    override a netclass, so clearance and track width belong there. A custom
    rule in the .kicad_dru with no condition would REPLACE the netclass value
    rather than act as a floor, which would silently drop the 1.0 mm Chassis
    clearance to the fab minimum. So the .kicad_dru carries only limits that
    Board Setup genuinely cannot express.

.NOTES
    Rule sources, checked 2026-10-25:
      index   https://community.aisler.net/t/pcb-design-rules/41
      2L HASL https://community.aisler.net/t/2-layer-1-6-mm-35-m-hasl-design-rules/3735
      2L ENIG https://community.aisler.net/t/2-layer-1-6mm-35-m-enig-design-rules/3732
      4L ENIG https://community.aisler.net/t/4-layer-35-m-enig-design-rules/3733
      base    https://github.com/AislerHQ/aisler-support  (kicad/*/*.kicad_dru)

    AISLER offers no HASL on 4 layers at 35 um, hence no 4L HASL rule set here.

    Caveat: "kicad-cli pcb drc" honours the .kicad_pro constraints but silently
    IGNORES .kicad_dru custom rules (verified on KiCad 10.0). Custom rules take
    effect only in the GUI DRC, which is also the only place their syntax gets
    validated. After changing them, run Board Setup > Custom Rules > Check Rule
    Syntax, because KiCad discards EVERY rule in the file if any one of them has
    an error, and it does so without complaining during a normal DRC run.

    Two things the generated .kicad_dru has to work around:
      - units must be mm, mil/th or in. "um" is a syntax error.
      - rules are evaluated in reverse order and matching stops at the first
        hit, so two rules sharing a condition and a constraint type cancel each
        other out. Each condition appears exactly once, with its constraints
        grouped into that single rule.

.EXAMPLE
    ./Apply-AislerRules.ps1

.EXAMPLE
    ./Apply-AislerRules.ps1 -Check
    Changes nothing; exits 1 if any file is out of date. Good as a pre-commit
    or CI check.
#>
[CmdletBinding()]
param(
    [string] $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')),
    [switch] $Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# AISLER rule sets. Every value in mm.
# ---------------------------------------------------------------------------
$RuleSets = @{
    '2L-1.6mm-35um-HASL' = @{
        Title          = '2 Layer 1.6mm 35um HASL'
        Doc            = 'https://community.aisler.net/t/2-layer-1-6-mm-35-m-hasl-design-rules/3735'
        TrackWidth     = 0.200
        Clearance      = 0.150
        EdgeClearance  = 0.300
        SmdPadMin      = 0.200
        ViaDrillMin    = 0.300
        ViaDrillMax    = 0.450
        ViaAnnular     = 0.175   # absolute minimum
        ViaAnnularPref = 0.200   # AISLER's preferred value
        PthDrillMin    = 0.500
        PthDrillMax    = 5.600
        PthAnnular     = 0.300
        NpthDrillMin   = 0.500
        NpthDrillMax   = 5.600
        NpthClearance  = 0.250
        SlotClearance  = 0.300
        HoleToHole     = 0.300
        SilkLineWidth  = 0.150
        SilkTextHeight = 0.800
        SilkClearance  = 0.125
        MaskDam        = 0.100
        MaskDamNote    = 'REQUIRED for HASL'
        Castellations  = $false
    }
    '2L-1.6mm-35um-ENIG' = @{
        Title          = '2 Layer 1.6mm 35um ENIG'
        Doc            = 'https://community.aisler.net/t/2-layer-1-6mm-35-m-enig-design-rules/3732'
        TrackWidth     = 0.125
        Clearance      = 0.125
        EdgeClearance  = 0.300
        SmdPadMin      = 0.200
        ViaDrillMin    = 0.250
        ViaDrillMax    = 0.450
        ViaAnnular     = 0.100
        ViaAnnularPref = 0.100
        PthDrillMin    = 0.500
        PthDrillMax    = 5.600
        PthAnnular     = 0.300
        NpthDrillMin   = 0.500
        NpthDrillMax   = 5.600
        NpthClearance  = 0.250
        SlotClearance  = 0.300
        HoleToHole     = 0.300
        SilkLineWidth  = 0.150
        SilkTextHeight = 0.800
        SilkClearance  = 0.125
        MaskDam        = 0.100
        MaskDamNote    = 'recommended, not required'
        Castellations  = $true
    }
    '4L-1.6mm-35um-ENIG' = @{
        Title          = '4 Layer 1.6mm 35um ENIG'
        Doc            = 'https://community.aisler.net/t/4-layer-35-m-enig-design-rules/3733'
        TrackWidth     = 0.125
        Clearance      = 0.125
        EdgeClearance  = 0.300
        SmdPadMin      = 0.200
        ViaDrillMin    = 0.250
        ViaDrillMax    = 0.450
        ViaAnnular     = 0.100
        ViaAnnularPref = 0.100
        PthDrillMin    = 0.500
        PthDrillMax    = 5.600
        PthAnnular     = 0.300
        NpthDrillMin   = 0.500
        NpthDrillMax   = 5.600
        NpthClearance  = 0.250
        SlotClearance  = 0.300
        HoleToHole     = 0.300
        SilkLineWidth  = 0.150
        SilkTextHeight = 0.800
        SilkClearance  = 0.125
        MaskDam        = 0.100
        MaskDamNote    = 'recommended, not required'
        Castellations  = $true
    }
}

# Which rule set each project is manufactured with.
$Projects = [ordered] @{
    'Right_Keypad' = '2L-1.6mm-35um-ENIG'
    'Shared_Main'  = '4L-1.6mm-35um-ENIG'
}

# Fab limits should not be reported as warnings you can scroll past.
$Severities = [ordered] @{
    annular_width         = 'error'
    clearance             = 'error'
    copper_edge_clearance = 'error'
    drill_out_of_range    = 'error'
    hole_clearance        = 'error'
    hole_to_hole          = 'error'
    items_not_allowed     = 'error'
    solder_mask_bridge    = 'error'
    text_height           = 'error'
    text_thickness        = 'error'
    track_width           = 'error'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
$inv = [cultureinfo]::InvariantCulture

function Format-Mm([double] $v) { [string]::Format($inv, '{0:0.0###}', $v) }
function Format-Um([double] $v) { [string] ([int] [math]::Round($v * 1000)) }

function Get-Constraints([hashtable] $r) {
    [ordered] @{
        # KiCad applies "minimum through hole" to via drills as well as PTH
        # drills, so it has to carry the VIA minimum. The PTH-only 0.5 mm floor
        # is enforced by a custom rule in the .kicad_dru instead.
        min_through_hole_diameter = $r.ViaDrillMin
        min_via_annular_width     = $r.ViaAnnular
        min_via_diameter          = [math]::Round($r.ViaDrillMin + 2 * $r.ViaAnnular, 3)
        min_clearance             = $r.Clearance
        min_track_width           = $r.TrackWidth
        min_copper_edge_clearance = $r.EdgeClearance
        min_hole_clearance        = $r.NpthClearance
        min_hole_to_hole          = $r.HoleToHole
        min_text_height           = $r.SilkTextHeight
        min_text_thickness        = $r.SilkLineWidth
        min_silk_clearance        = $r.SilkClearance
    }
}

# Walks a JSON object to its matching closing brace, honouring string literals
# so that a brace inside a string cannot throw off the depth count.
function Find-BlockEnd([string] $text, [int] $afterOpenBrace) {
    $depth = 1
    $i = $afterOpenBrace
    $inString = $false
    $escaped = $false
    while ($i -lt $text.Length) {
        $c = $text[$i]
        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq '"') { $inString = $false }
        }
        else {
            if ($c -eq '"') { $inString = $true }
            elseif ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { return $i } }
        }
        $i++
    }
    throw 'Unbalanced JSON braces.'
}

# Locates a named JSON object, optionally restricted to a span of the file.
# "rule_severities" occurs twice in a .kicad_pro, once for the board's DRC and
# once for the schematic's ERC, so the caller has to be able to say which span
# to look in rather than trusting whichever comes first.
function Get-BlockBounds([string] $text, [string] $name, [int] $from = 0, [int] $to = -1) {
    if ($to -lt 0) { $to = $text.Length }
    $rx = [regex] ('"' + [regex]::Escape($name) + '"\s*:\s*\{')
    $m = $rx.Match($text, $from, $to - $from)
    if (-not $m.Success) { throw "JSON block '$name' not found in the given span." }
    $open = $m.Index + $m.Length
    return @{ Open = $open; Close = (Find-BlockEnd $text $open) }
}

# Replaces scalar values inside one named JSON object, leaving every other byte
# of the file untouched. Keeps the diff to the lines that actually changed
# rather than reserialising the whole project file.
function Set-JsonScalars([string] $text, [string] $blockName, $values) {
    # Anchor inside board.design_settings so the schematic's ERC block is never
    # a candidate.
    $ds = Get-BlockBounds $text 'design_settings'
    $block = Get-BlockBounds $text $blockName $ds.Open $ds.Close
    $open = $block.Open
    $close = $block.Close
    $body = $text.Substring($open, $close - $open)
    $changes = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $values.Keys) {
        $raw = $values[$key]
        $literal = if ($raw -is [bool]) { $raw.ToString().ToLowerInvariant() }
                   elseif ($raw -is [string]) { '"' + $raw + '"' }
                   else { Format-Mm $raw }

        $pattern = '("' + [regex]::Escape($key) + '"\s*:\s*)(true|false|null|-?[0-9][0-9.eE+\-]*|"[^"]*")'
        $hit = [regex]::Match($body, $pattern)
        if (-not $hit.Success) {
            Write-Warning "  $blockName.$key not present in this project file, skipped."
            continue
        }
        if ($hit.Groups[2].Value -eq $literal) { continue }
        $changes.Add("$key : $($hit.Groups[2].Value) -> $literal")
        $body = $body.Remove($hit.Groups[2].Index, $hit.Groups[2].Length).
                      Insert($hit.Groups[2].Index, $literal)
    }

    return @{
        Text    = $text.Substring(0, $open) + $body + $text.Substring($close)
        Changes = $changes
    }
}

function New-DruText([hashtable] $r, [string] $setName) {
    $mmClear   = Format-Mm $r.Clearance
    $mmTrack   = Format-Mm $r.TrackWidth
    $mmEdge    = Format-Mm $r.EdgeClearance
    $mmViaMin  = Format-Mm $r.ViaDrillMin
    $mmViaMax  = Format-Mm $r.ViaDrillMax
    $mmViaAnn  = Format-Mm $r.ViaAnnular
    $mmViaDia  = Format-Mm ([math]::Round($r.ViaDrillMin + 2 * $r.ViaAnnular, 3))
    $mmPthMin  = Format-Mm $r.PthDrillMin
    $mmPthMax  = Format-Mm $r.PthDrillMax
    $mmNpthMin = Format-Mm $r.NpthDrillMin
    $mmNpthMax = Format-Mm $r.NpthDrillMax
    $mmHoleClr = Format-Mm $r.NpthClearance
    $mmH2H     = Format-Mm $r.HoleToHole
    $mmTextH   = Format-Mm $r.SilkTextHeight
    $mmTextT   = Format-Mm $r.SilkLineWidth
    $mmSilkClr = Format-Mm $r.SilkClearance

    $mmPthAnn  = Format-Mm $r.PthAnnular
    $mmSmd     = Format-Mm $r.SmdPadMin

    $umPth     = Format-Um $r.PthAnnular
    $umSmd     = Format-Um $r.SmdPadMin
    $umMask    = Format-Um $r.MaskDam
    $umSlot    = Format-Um $r.SlotClearance
    $umSilk    = Format-Um $r.SilkLineWidth

    $castNote = if ($r.Castellations) { 'supported on this rule set, free of charge' }
                else { 'NOT supported with HASL' }

    # Shared between the two pad rules below, which are kept disjoint on purpose.
    $maskOk = 'A.Soldermask_Margin_Override == 0mm || A.Soldermask_Margin_Override == null'

    $text = @"
(version 1.1)
#----------------------------------------------------------------------------------------------------
# AISLER design rules - $($r.Title)
#
# GENERATED by PCBs/design-rules/Apply-AislerRules.ps1 - do not edit by hand.
# Rule set: $setName
# Source:   $($r.Doc)
#           https://github.com/AislerHQ/aisler-support  (official base rules, merged in below)
#
# This file carries only the limits KiCad has no Board Setup field for. The rest
# are in <project>.kicad_pro under board.design_settings.rules:
#   min_clearance             $mmClear
#   min_track_width           $mmTrack
#   min_copper_edge_clearance $mmEdge
#   min_through_hole_diameter $mmViaMin      (KiCad applies this to via drills too)
#   min_via_annular_width     $mmViaAnn
#   min_via_diameter          $mmViaDia
#   min_hole_clearance        $mmHoleClr
#   min_hole_to_hole          $mmH2H
#   min_text_height           $mmTextH
#   min_text_thickness        $mmTextT
#   min_silk_clearance        $mmSilkClr
#
# Not machine-checkable at all. Verify these by eye before ordering:
#   - silkscreen must cover at most 25% of each side, or the job is rejected
#   - soldermask dam between pads $umMask um ($($r.MaskDamNote))
#   - NPTH slot to copper $umSlot um; slots under 1.8 mm are nibbled and may be refused
#   - silkscreen graphic line width $umSilk um is set in
#     Board Setup > Text & Graphics Defaults, not in Constraints
#   - castellated edges are $castNote
#----------------------------------------------------------------------------------------------------


#--- Notes on how these are written ------------------------------------------------------------------
#
# Units must be mm, mil/th or in. KiCad rejects "um" as a syntax error, and ONE
# error anywhere in this file makes KiCad discard EVERY rule in it, silently. So
# all values below are mm even where AISLER publishes them in um.
#
# Rules are evaluated in REVERSE order and matching stops at the first hit, so
# the last matching rule wins. Two rules that share a condition and a constraint
# type therefore cancel each other out: AISLER's own published file splits the
# via bans into two "disallow" rules and keeps the PTH max drill apart from any
# min, which means whichever lands later silently wins. Each condition is
# written once here, with all of its constraints grouped into that one rule.
#
#-----------------------------------------------------------------------------------------------------


# AISLER does not support micro or buried vias.
# Merged into one rule: two separate "disallow" rules would mask one another.
(rule "AISLER unsupported via types"
    (constraint disallow buried_via micro_via))

# The soldermask is pulled back to account for slight misalignment during
# manufacturing. AISLER does this themselves, so per-pad margins must stay at 0.
#
# This and the SMD rule at the bottom of the file are deliberately kept to
# mutually exclusive conditions. Both carry an "assertion" constraint, and the
# manual does not say whether every matching assertion is evaluated or whether
# reverse-order first-match-wins applies to assertions as it does to resolved
# values. Disjoint conditions are correct either way.
(rule "AISLER soldermask margin, non-SMD pads"
    (constraint assertion "$maskOk")
    (condition "A.Type == 'Pad' && A.Pad_Type != 'SMD'"))

# Plated through holes.
#   drill $mmPthMin mm .. $mmPthMax mm   AISLER's tooling is finite:
#                             https://community.aisler.net/t/plated-and-non-plated-holes/50
#   annular ring min $umPth um   KiCad's Board Setup "minimum annular width" covers
#                             vias only, so the PTH ring has to be checked here.
# The drill floor also has to live here rather than in Board Setup, because
# Board Setup's "minimum through hole" is applied to via drills as well and
# carries $mmViaMin mm for that reason.
(rule "AISLER plated through holes"
    (constraint hole_size (min ${mmPthMin}mm) (max ${mmPthMax}mm))
    (constraint annular_width (min ${mmPthAnn}mm))
    (condition "A.Pad_Type == 'Through-hole'"))

# Non-plated holes, drill $mmNpthMin mm .. $mmNpthMax mm.
(rule "AISLER non-plated holes"
    (constraint hole_size (min ${mmNpthMin}mm) (max ${mmNpthMax}mm))
    (condition "A.Pad_Type == 'NPTH, mechanical'"))

# Vias, drill $mmViaMin mm .. $mmViaMax mm. Anything over $mmViaMax mm is treated as a PTH and
# enlarged to offset the plating, so it must then meet the PTH rules instead.
# Listed after the PTH rule so that it wins under reverse-order evaluation.
(rule "AISLER vias"
    (constraint hole_size (min ${mmViaMin}mm) (max ${mmViaMax}mm))
    (condition "A.Type == 'Via'"))

# SMD pads: minimum size $umSmd um, which KiCad has no constraint type for, plus
# the same soldermask margin check as above. Both are in one assertion here
# because this rule's condition is disjoint from the non-SMD pad rule's.
(rule "AISLER SMD pads"
    (constraint assertion "($maskOk) && A.Size_X >= ${mmSmd}mm && A.Size_Y >= ${mmSmd}mm")
    (condition "A.Pad_Type == 'SMD'"))
"@

    return ($text -replace "`r`n", "`n")
}

# Netclasses and pre-defined via sizes are design intent, so this only reports
# on them. A netclass via that is legal on ENIG can still be illegal on HASL,
# which is exactly the trap that blocks HASL at checkout.
function Test-NetClasses([string] $proPath, [hashtable] $r) {
    $doc = Get-Content -Raw -LiteralPath $proPath | ConvertFrom-Json
    if (-not $doc.PSObject.Properties.Name.Contains('net_settings')) { return }

    foreach ($nc in $doc.net_settings.classes) {
        $name = $nc.name
        foreach ($pair in @(
                @{ Prop = 'clearance';   Min = $r.Clearance;  Label = 'clearance' },
                @{ Prop = 'track_width'; Min = $r.TrackWidth; Label = 'track width' })) {
            if ($nc.PSObject.Properties.Name.Contains($pair.Prop)) {
                $v = [double] $nc.($pair.Prop)
                if ($v -lt $pair.Min) {
                    Write-Warning ("  netclass '$name' $($pair.Label) $(Format-Mm $v) mm is below" +
                        " the fab minimum $(Format-Mm $pair.Min) mm")
                }
            }
        }
        if ($nc.PSObject.Properties.Name.Contains('via_diameter') -and
            $nc.PSObject.Properties.Name.Contains('via_drill')) {
            $dia = [double] $nc.via_diameter
            $drill = [double] $nc.via_drill
            $ring = ($dia - $drill) / 2
            $via = "$(Format-Mm $dia)/$(Format-Mm $drill)"
            if ($ring -lt $r.ViaAnnular) {
                Write-Warning ("  netclass '$name' via $via gives a $(Format-Mm $ring) mm annular ring," +
                    " below the $(Format-Mm $r.ViaAnnular) mm minimum")
            }
            elseif ($ring -lt $r.ViaAnnularPref) {
                Write-Warning ("  netclass '$name' via $via gives a $(Format-Mm $ring) mm annular ring;" +
                    " AISLER prefers $(Format-Mm $r.ViaAnnularPref) mm")
            }
            if ($drill -lt $r.ViaDrillMin -or $drill -gt $r.ViaDrillMax) {
                Write-Warning ("  netclass '$name' via drill $(Format-Mm $drill) mm is outside" +
                    " $(Format-Mm $r.ViaDrillMin)..$(Format-Mm $r.ViaDrillMax) mm")
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$stale = $false

foreach ($projName in $Projects.Keys) {
    $setName = $Projects[$projName]
    if (-not $RuleSets.Contains($setName)) { throw "Unknown rule set '$setName'." }
    $rules = $RuleSets[$setName]

    $dir = Join-Path $Root $projName
    $pro = Join-Path $dir "$projName.kicad_pro"
    $dru = Join-Path $dir "$projName.kicad_dru"
    if (-not (Test-Path -LiteralPath $pro)) { throw "Project not found: $pro" }

    Write-Host ''
    Write-Host "$projName  ->  $($rules.Title)" -ForegroundColor Cyan

    # --- .kicad_dru --------------------------------------------------------
    $wanted = New-DruText $rules $setName
    $current = if (Test-Path -LiteralPath $dru) {
        (Get-Content -Raw -LiteralPath $dru) -replace "`r`n", "`n"
    } else { '' }

    if ($current -ne $wanted) {
        $stale = $true
        if ($Check) {
            Write-Host "  [stale] $projName.kicad_dru" -ForegroundColor Yellow
        }
        else {
            [System.IO.File]::WriteAllText($dru, $wanted, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  wrote  $projName.kicad_dru" -ForegroundColor Green
        }
    }
    else {
        Write-Host "  ok     $projName.kicad_dru"
    }

    # --- .kicad_pro --------------------------------------------------------
    $text = Get-Content -Raw -LiteralPath $pro
    $original = $text

    $step = Set-JsonScalars $text 'rules' (Get-Constraints $rules)
    $text = $step.Text
    $constraintChanges = $step.Changes

    $step = Set-JsonScalars $text 'rule_severities' $Severities
    $text = $step.Text
    $severityChanges = $step.Changes

    if ($text -ne $original) {
        $stale = $true
        foreach ($c in $constraintChanges) { Write-Host "         constraint  $c" }
        foreach ($c in $severityChanges) { Write-Host "         severity    $c" }
        if ($Check) {
            Write-Host "  [stale] $projName.kicad_pro" -ForegroundColor Yellow
        }
        else {
            [System.IO.File]::WriteAllText($pro, $text, [System.Text.UTF8Encoding]::new($false))
            Write-Host "  wrote  $projName.kicad_pro" -ForegroundColor Green
        }
    }
    else {
        Write-Host "  ok     $projName.kicad_pro"
    }

    Test-NetClasses $pro $rules
}

Write-Host ''
if ($Check -and $stale) {
    Write-Host 'Design rules are out of date. Run Apply-AislerRules.ps1.' -ForegroundColor Yellow
    exit 1
}
if (-not $Check -and $stale) {
    Write-Host 'Close and reopen the boards in KiCad, then run DRC once to validate the custom rules.' -ForegroundColor Yellow
}
exit 0
