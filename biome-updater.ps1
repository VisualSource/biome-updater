param(
    [switch]$Uninstall = $false,
    [switch]$NoSchedule = $false,
    [switch]$Setup = $false
)

Add-Type -AssemblyName System.Windows.Forms

function Remove-File {
    param (
        $Path
    )

    if (Test-Path -Path $Path) {
        Remove-Item -Path $Path -Force
    }
}

function Install-Task {
    param (
        [string]$ScriptFolder,
        [string]$Script
    )

    Write-Host "Debug" $ScriptFolder $Script

    if (Get-ScheduledTask -TaskName 'BiomeUpdater' -ErrorAction SilentlyContinue) {
        Write-Host "Task 'BiomeUpdater' already registered"
        return 
    }

    Write-Host "Registering Task 'BiomeUpdater'"
    $action = New-ScheduledTaskAction 'powershell.exe' -WorkingDirectory $ScriptFolder -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -file $($scriptPath)"
    $trigger = New-ScheduledTaskTrigger -Daily -At '11:00 AM'
    $settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable
    $user = $env:USERNAME
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings

    Register-ScheduledTask -TaskName 'BiomeUpdater' -InputObject $task -User $user | Out-Null
}

function Install-Biome {
    param (
        $Content
    )

    try {
        $item = $Content.assets | Where-Object { $_.name.StartsWith("biome-win32-x64") }
        if (!$item) {
            Write-Error "Failed to find asset 'biome-win32-x64.exe'"
            return null
        }

        $digest = $item.digest.Split(":")
        $alg = $digest[0].ToUpper()
        $hash = $digest[1].ToUpper()
        $outfile = Join-Path -Path $biomeFolder -ChildPath $item.name

        Remove-File -Path $outfile
        Write-Host "Downloading file from: $($item.browser_download_url)"
        Write-Host "Writing file to: $($outfile)"

        $updater = New-Object System.Diagnostics.ProcessStartInfo
        $updater.WorkingDirectory = $biomeFolder
        $updater.FileName = "updater.exe"
        $updater.RedirectStandardError = $true
        $updater.RedirectStandardOutput = $true   
        $updater.UseShellExecute = $false
        $updater.Arguments = "$($item.browser_download_url) $($outfile)"    

        $c = New-Object System.Diagnostics.Process 
        $c.StartInfo = $updater
        $c.Start() | Out-Null
        $c.WaitForExit()
        $stdout = $c.StandardOutput.ReadToEnd()
        $stderr = $c.StandardError.ReadToEnd()
 
        if ($c.ExitCode -ne 0) {
            throw $stderr
        } else {
            Write-Host $stdout
        }

        $result = Get-FileHash -Path $outfile -Algorithm $alg

        if (!($hash -eq $result.Hash)) {
            throw "file hash did not match download file! Was expecting '$($hash)' but got '$($result.Hash)'"
        }

        if (Test-Path -Path $biomeExe) {
            Remove-Item -Path $biomeExe -Force
        }

        Rename-Item -Path $outfile -NewName "biome.exe"
    }
    catch {
        Write-Error $_.Exception.Message
        if ($outfile) {
            Remove-File -Path $outfile
        }
    }
}

function Get-LatestVersion {
    Write-Host "Fetching latest biome version"
    $response = Invoke-WebRequest "https://api.github.com/repos/biomejs/biome/releases/latest"

    if (!($response.StatusCode -eq 200)) {
        Write-Error "Request failed with status: $($response.StatusCode)"
        return $null;
    }

    $content = $response.Content | ConvertFrom-Json
    [string]$latestVersion = $content.tag_name.Replace("@biomejs/biome@", "").Trim("`r","`n","`f",' ')

    Write-Host "Latest git tag found $($latestVersion)"

    return @{
        Content = $content
        Version = $latestVersion
    }
}

function Start-Updater {
    if (!(Get-Command biome.exe -ErrorAction SilentlyContinue)) {
        $latest = Get-LatestVersion
        if ($null -eq $latest) {
            throw 'Failed to fetch latest biome version from github'
        }

        $result = [System.Windows.Forms.MessageBox]::Show(
                "Whould you like to install biome?", 
                "Biome updater", 
                [System.Windows.Forms.MessageBoxButtons]::OKCancel)

        if (!($result -eq [System.Windows.Forms.DialogResult]::Ok)) {
            Write-Host "Install was declined"
            return
        }

        Write-Host "Installing Biome V$($latest.Version)"
        Install-Biome -Content $latest.Content
        return
    }

    [string]$currentBiomeVersion = ((biome --version).Replace('Version: ','').Trim("`r","`f","`n", ' '))
    Write-Host "Installed Biome Version: $($currentBiomeVersion)"

    $latest = Get-LatestVersion

    if ($null -eq $latest) {
        throw 'Failed to fetch latest biome version from github'
    }

    [version]$cb = $currentBiomeVersion
    [version]$lb = $latest.Version

    if ($lb.Major -eq $cb.Major -and $lb.Minor -eq $cb.Minor -and $lb.Build -eq $cb.Build) {
        Write-Host "Biome is at latest" 
        return
    }

    $result = [System.Windows.Forms.MessageBox]::Show(
        "Biome has version $($latest.Version) (Current $($currentBiomeVersion))`n Would you like to Update?", 
        "Biome update", 
        [System.Windows.Forms.MessageBoxButtons]::OKCancel)

    if (!($result -eq [System.Windows.Forms.DialogResult]::Ok)) {
        Write-Host "Update was declined"
        return
    }

    Install-Biome -Content $latest.Content
}

$exitCode = 0
try {
    $biomeFolder = Join-Path -Path $env:USERPROFILE -ChildPath "/biome"
    $biomeExe = Join-Path -Path $biomeFolder -ChildPath "biome.exe"

    if (-not (Test-Path -Path $biomeFolder)) {
        mkdir $biomeFolder
    }
    Write-Host "Install directory: $($biomeFolder)"

    $logPath = Join-Path -Path $biomeFolder -ChildPath 'updater.log'
    Start-Transcript -Path $logPath -Append -NoClobber

    if ($Uninstall) {
        Unregister-ScheduledTask -TaskName 'BiomeUpdater'
        Remove-Item -Path $biomeFolder -Recurse
        return 
    }

    if($Setup){
        if(-not $NoSchedule) {
            Install-Task -ScriptFolder $biomeFolder -Script 'biome-updater.ps1'
        }

        $archive = Join-Path -Path $biomeFolder -ChildPath 'BiomeUpdater.zip'
        Invoke-WebRequest -Uri 'https://github.com/VisualSource/biome-updater/releases/download/v0.0.1/BiomeUpdater.zip' -OutFile $archive
        $result = Get-FileHash -Path $archive -Algorithm 'SHA256'

        if (!("12EFFB507E9EA5AC400F7D3AE1D811BD57D920D5C22C5D79B9C8B61838A4A026" -eq $result.Hash)) {
            throw "file hash did not match download file! Was expecting '12EFFB507E9EA5AC400F7D3AE1D811BD57D920D5C22C5D79B9C8B61838A4A026' but got '$($result.Hash)'"
        }

        Expand-Archive -Path $archive -DestinationPath $biomeFolder
        Remove-File -Path $archive
    }
    
    Start-Updater
}
catch {
    Write-Error $_.Exception.Message
    $exitCode = 1
}
finally {
    Stop-Transcript
    exit $exitCode
}
