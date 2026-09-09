$ErrorActionPreference = 'Stop'

$script:LinuxEnvelopeAlgorithm = 'AES-256-GCM+Linux-User-Key'

function Assert-LinuxRuntime {
    if (-not $IsLinux -or $PSVersionTable.PSVersion -lt [version]'7.4') {
        throw [PlatformNotSupportedException]::new('The Linux dashboard security module requires PowerShell 7.4 or later on Linux.')
    }
}

function Set-LinuxPrivateDirectoryPermissions {
    param([Parameter(Mandatory)][string]$Path)

    Assert-LinuxRuntime
    [IO.File]::SetUnixFileMode(
        $Path,
        [IO.UnixFileMode]::UserRead -bor
        [IO.UnixFileMode]::UserWrite -bor
        [IO.UnixFileMode]::UserExecute
    )
}

function Set-LinuxPrivateFilePermissions {
    param([Parameter(Mandatory)][string]$Path)

    Assert-LinuxRuntime
    [IO.File]::SetUnixFileMode(
        $Path,
        [IO.UnixFileMode]::UserRead -bor
        [IO.UnixFileMode]::UserWrite
    )
}

function Get-LinuxDashboardKey {
    param([Parameter(Mandatory)][string]$KeyPath)

    Assert-LinuxRuntime
    $directory = Split-Path -Parent $KeyPath
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Set-LinuxPrivateDirectoryPermissions -Path $directory

    if (-not (Test-Path -LiteralPath $KeyPath)) {
        $newKey = [byte[]]::new(32)
        [Security.Cryptography.RandomNumberGenerator]::Fill($newKey)
        try {
            try {
                $options = [IO.FileStreamOptions]@{
                    Mode = [IO.FileMode]::CreateNew
                    Access = [IO.FileAccess]::Write
                    Share = [IO.FileShare]::None
                    UnixCreateMode = [IO.UnixFileMode]::UserRead -bor
                        [IO.UnixFileMode]::UserWrite
                }
                $stream = [IO.FileStream]::new($KeyPath, $options)
                try {
                    $stream.Write($newKey, 0, $newKey.Length)
                    $stream.Flush($true)
                }
                finally {
                    $stream.Dispose()
                }
            }
            catch [IO.IOException] {
                if (-not (Test-Path -LiteralPath $KeyPath)) {
                    throw
                }
            }
        }
        finally {
            [Array]::Clear($newKey, 0, $newKey.Length)
        }
    }

    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        try {
            Set-LinuxPrivateFilePermissions -Path $KeyPath
            $key = [IO.File]::ReadAllBytes($KeyPath)
            if ($key.Length -eq 32) {
                return $key
            }
            [Array]::Clear($key, 0, $key.Length)
        }
        catch [IO.IOException] {
            if ($attempt -eq 39) {
                throw
            }
        }
        Start-Sleep -Milliseconds 25
    }
    throw [IO.InvalidDataException]::new('The Linux dashboard key must contain exactly 32 bytes.')
}

function New-LinuxDashboardAesGcm {
    param([Parameter(Mandatory)][byte[]]$Key)

    return [Security.Cryptography.AesGcm]::new($Key, 16)
}

function Write-LinuxPrivateTextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    Assert-LinuxRuntime
    $options = [IO.FileStreamOptions]@{
        Mode = [IO.FileMode]::CreateNew
        Access = [IO.FileAccess]::Write
        Share = [IO.FileShare]::None
        UnixCreateMode = [IO.UnixFileMode]::UserRead -bor
            [IO.UnixFileMode]::UserWrite
    }
    $stream = [IO.FileStream]::new($Path, $options)
    try {
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false), 1024, $true)
        try {
            $writer.Write($Text)
            $writer.Flush()
            $stream.Flush($true)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Protect-LinuxDashboardPayload {
    param(
        [Parameter(Mandatory)][string]$PlainText,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,63}$')][string]$Purpose
    )

    $key = Get-LinuxDashboardKey -KeyPath $KeyPath
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    $nonce = [byte[]]::new(12)
    $tag = [byte[]]::new(16)
    $cipherText = [byte[]]::new($plainBytes.Length)
    $associatedData = [Text.Encoding]::UTF8.GetBytes("ArcDashboard:$Purpose:v1")
    [Security.Cryptography.RandomNumberGenerator]::Fill($nonce)
    try {
        $aes = New-LinuxDashboardAesGcm -Key $key
        try {
            $aes.Encrypt($nonce, $plainBytes, $cipherText, $tag, $associatedData)
        }
        finally {
            $aes.Dispose()
        }
        return [ordered]@{
            version = 1
            algorithm = $script:LinuxEnvelopeAlgorithm
            purpose = $Purpose
            nonce = [Convert]::ToBase64String($nonce)
            tag = [Convert]::ToBase64String($tag)
            data = [Convert]::ToBase64String($cipherText)
        } | ConvertTo-Json -Compress
    }
    finally {
        [Array]::Clear($key, 0, $key.Length)
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        [Array]::Clear($associatedData, 0, $associatedData.Length)
    }
}

function Unprotect-LinuxDashboardPayload {
    param(
        [Parameter(Mandatory)][string]$ProtectedText,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,63}$')][string]$Purpose
    )

    $envelope = $ProtectedText | ConvertFrom-Json
    if ([int]$envelope.version -ne 1 -or
        [string]$envelope.algorithm -ne $script:LinuxEnvelopeAlgorithm -or
        [string]$envelope.purpose -ne $Purpose) {
        throw [IO.InvalidDataException]::new('The Linux dashboard encryption envelope is not supported.')
    }

    $key = Get-LinuxDashboardKey -KeyPath $KeyPath
    $nonce = [Convert]::FromBase64String([string]$envelope.nonce)
    $tag = [Convert]::FromBase64String([string]$envelope.tag)
    $cipherText = [Convert]::FromBase64String([string]$envelope.data)
    $plainBytes = [byte[]]::new($cipherText.Length)
    $associatedData = [Text.Encoding]::UTF8.GetBytes("ArcDashboard:$Purpose:v1")
    try {
        $aes = New-LinuxDashboardAesGcm -Key $key
        try {
            $aes.Decrypt($nonce, $cipherText, $tag, $plainBytes, $associatedData)
        }
        finally {
            $aes.Dispose()
        }
        return [Text.Encoding]::UTF8.GetString($plainBytes)
    }
    finally {
        [Array]::Clear($key, 0, $key.Length)
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        [Array]::Clear($associatedData, 0, $associatedData.Length)
    }
}

Export-ModuleMember -Function @(
    'Protect-LinuxDashboardPayload',
    'Unprotect-LinuxDashboardPayload',
    'Set-LinuxPrivateDirectoryPermissions',
    'Set-LinuxPrivateFilePermissions',
    'Write-LinuxPrivateTextFile'
)
