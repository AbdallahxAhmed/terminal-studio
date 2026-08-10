#Requires -Version 5.1

<#
    Terminal Studio - managed shell profile (Andalus)

    Deployed to $PROFILE.CurrentUserCurrentHost. Everything here is optional at
    runtime: each feature checks for its dependency and skips silently when it is
    absent, so a partially provisioned machine still opens a working shell.
#>

$__tsStart = [Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------- encoding ---
# The prompt draws from the Private Use Area. Under Windows PowerShell the
# console defaults to the OEM code page and those code points degrade to '?',
# which is indistinguishable from a missing font and sends debugging sideways.
try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $OutputEncoding = [Text.UTF8Encoding]::new($false)
}
catch {
    Write-Verbose "Could not set UTF-8 console encoding: $($_.Exception.Message)"
}

# -------------------------------------------------------------- oh-my-posh ---
$__omp = Get-Command -Name 'oh-my-posh' -CommandType Application -ErrorAction SilentlyContinue

if ($__omp) {
    # 'powershell' and 'pwsh' are distinct init targets. Passing the wrong one
    # emits a shell hook that silently fails to install the prompt function.
    $__ompShell = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }
    $__ompTheme = Join-Path -Path $HOME -ChildPath '.poshthemes\andalus.omp.json'

    try {
        if (Test-Path -LiteralPath $__ompTheme) {
            (& $__omp.Source init $__ompShell --config $__ompTheme) -join "`n" | Invoke-Expression
        }
        else {
            Write-Warning 'Andalus prompt theme not found; falling back to the oh-my-posh default.'
            (& $__omp.Source init $__ompShell) -join "`n" | Invoke-Expression
        }
    }
    catch {
        Write-Warning "oh-my-posh failed to initialise: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------- Terminal-Icons ---
# This is what colours and glyphs the directory listing.
if (Get-Module -ListAvailable -Name 'Terminal-Icons' -ErrorAction SilentlyContinue) {
    Import-Module -Name 'Terminal-Icons' -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------ z jump ---
if (Get-Module -ListAvailable -Name 'z' -ErrorAction SilentlyContinue) {
    Import-Module -Name 'z' -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------- PSReadLine ---
$__prl = Get-Module -ListAvailable -Name 'PSReadLine' -ErrorAction SilentlyContinue |
    Sort-Object -Property Version -Descending |
    Select-Object -First 1

if ($__prl) {
    Import-Module -Name 'PSReadLine' -ErrorAction SilentlyContinue

    # Andalus, as SGR sequences. PSReadLine takes ANSI strings, not colour names,
    # for anything outside the sixteen console slots.
    Set-PSReadLineOption -Colors @{
        Command                = "`e[38;2;212;165;55m"    # gold
        Parameter              = "`e[38;2;91;143;204m"    # bright blue
        Operator               = "`e[38;2;138;147;168m"   # muted
        Variable               = "`e[38;2;73;197;182m"    # bright cyan
        String                 = "`e[38;2;143;191;122m"   # bright green
        Number                 = "`e[38;2;181;138;196m"   # bright purple
        Type                   = "`e[38;2;46;158;147m"    # cyan
        Comment                = "`e[38;2;58;67;88m"      # bright black
        Keyword                = "`e[38;2;224;160;60m"    # amber
        Error                  = "`e[38;2;224;106;94m"    # bright red
        InlinePrediction       = "`e[38;2;58;67;88m"
        Selection              = "`e[48;2;45;93;143m"
    }

    Set-PSReadLineOption -EditMode Windows
    Set-PSReadLineOption -BellStyle None
    Set-PSReadLineOption -HistoryNoDuplicates
    Set-PSReadLineOption -MaximumHistoryCount 8192

    # ListView and the plugin source both arrived in 2.2. Asking for them on an
    # older build throws rather than degrading.
    if ($__prl.Version -ge [Version]'2.2.0') {
        $__source = if (Get-Module -ListAvailable -Name 'CompletionPredictor' -ErrorAction SilentlyContinue) {
            'HistoryAndPlugin'
        }
        else {
            'History'
        }

        Set-PSReadLineOption -PredictionSource $__source
        Set-PSReadLineOption -PredictionViewStyle ListView
    }

    Set-PSReadLineKeyHandler -Key 'Tab'        -Function MenuComplete
    Set-PSReadLineKeyHandler -Key 'UpArrow'    -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key 'DownArrow'  -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key 'Ctrl+d'     -Function DeleteCharOrExit
}

# ------------------------------------------------------------------ posh-git ---
if (Get-Module -ListAvailable -Name 'posh-git' -ErrorAction SilentlyContinue) {
    Import-Module -Name 'posh-git' -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------ niceties ---
Set-Alias -Name 'll' -Value 'Get-ChildItem' -ErrorAction SilentlyContinue

function which {
    <#
        .SYNOPSIS
            Resolves a command to its definition, the way the unix tool does.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Name
    )

    Get-Command -Name $Name -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty 'Definition'
}

$__tsStart.Stop()
$TSProfileMs = [int] $__tsStart.Elapsed.TotalMilliseconds

Remove-Variable -Name '__tsStart', '__omp', '__ompShell', '__ompTheme', '__prl', '__source' -ErrorAction SilentlyContinue
