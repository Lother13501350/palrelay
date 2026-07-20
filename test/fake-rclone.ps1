# Minimal rclone stand-in for offline tests. Maps "fake:<path>" to a local
# folder given by FAKE_RCLONE_ROOT. Supports: cat, copyto, deletefile, lsjson.

$root = $env:FAKE_RCLONE_ROOT
if (-not $root) {
    [Console]::Error.WriteLine('fake-rclone: FAKE_RCLONE_ROOT is not set')
    exit 1
}

function Resolve-FakePath([string]$p) {
    if ($p -match '^fake:(.*)$') {
        $rel = $Matches[1] -replace '/', '\'
        $rel = $rel.TrimStart('\')
        if ($rel -eq '') { return $root }
        return (Join-Path $root $rel)
    }
    return $p
}

function Out-EntryJson($items) {
    $parts = @()
    foreach ($item in $items) {
        $size = [int64]0
        if (-not $item.PSIsContainer) { $size = [int64]$item.Length }
        $o = [pscustomobject]@{
            Path    = $item.Name
            Name    = $item.Name
            Size    = $size
            ModTime = $item.LastWriteTimeUtc.ToString('o')
            IsDir   = [bool]$item.PSIsContainer
        }
        $parts += ($o | ConvertTo-Json -Compress)
    }
    [Console]::Out.WriteLine('[' + ($parts -join ',') + ']')
}

$cmd = $args[0]
switch ($cmd) {
    'cat' {
        $p = Resolve-FakePath $args[1]
        if (-not (Test-Path $p -PathType Leaf)) { exit 3 }
        [Console]::Out.Write([IO.File]::ReadAllText($p))
        exit 0
    }
    'copyto' {
        $src = Resolve-FakePath $args[1]
        $dst = Resolve-FakePath $args[2]
        if (-not (Test-Path $src -PathType Leaf)) {
            [Console]::Error.WriteLine("fake-rclone: source not found: $($args[1])")
            exit 3
        }
        $dir = Split-Path -Parent $dst
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Copy-Item -Path $src -Destination $dst -Force
        exit 0
    }
    'moveto' {
        $src = Resolve-FakePath $args[1]
        $dst = Resolve-FakePath $args[2]
        if (-not (Test-Path $src)) {
            [Console]::Error.WriteLine("fake-rclone: source not found: $($args[1])")
            exit 3
        }
        $dir = Split-Path -Parent $dst
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Move-Item -Path $src -Destination $dst -Force
        exit 0
    }
    'deletefile' {
        $p = Resolve-FakePath $args[1]
        if (Test-Path $p -PathType Leaf) { Remove-Item -Path $p -Force }
        exit 0
    }
    'lsjson' {
        $p = Resolve-FakePath $args[1]
        if (-not (Test-Path $p)) { exit 3 }
        if (Test-Path $p -PathType Container) {
            Out-EntryJson @(Get-ChildItem -Path $p)
        } else {
            Out-EntryJson @(Get-Item -Path $p)
        }
        exit 0
    }
    default {
        [Console]::Error.WriteLine("fake-rclone: unsupported command '$cmd'")
        exit 1
    }
}
