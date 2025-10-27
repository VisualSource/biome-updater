Add-Type -AssemblyName PresentationFramework
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

    if (Get-ScheduledTask -TaskName 'BiomeUpdater' -ErrorAction SilentlyContinue) {
        Write-Host "Task 'BiomeUpdater' already registered"
        return 
    }

    $scriptPath = Join-Path -Path $ScriptFolder -ChildPath $Script
    if (-not (Test-Path -Path $scriptPath)) {
        Write-Host "Copying Invocation to script folder"
        Copy-Item -Path $MyInvocation.MyCommand.Path -Destination $scriptPath
    }

    Write-Host "Registering Task 'BiomeUpdater'"
    $action = New-ScheduledTaskAction 'powershell.exe' -WorkingDirectory $ScriptFolder -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -file $($scriptPath)"
    $trigger = New-ScheduledTaskTrigger -Daily -At '11:00 AM'
    $settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable
    $user = $env:USERNAME
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings

    Register-ScheduledTask -TaskName 'BiomeUpdater' -InputObject $task -User $user
    #Unregister-ScheduledTask -TaskName 'BiomeUpdater'
}

# https://gist.github.com/ChrisStro/37444dd012f79592080bd46223e27adc
function Get-FileFromWeb {
    param (
        # Parameter help description
        [Parameter(Mandatory)]
        [string]$URL,
  
        # Parameter help description
        [Parameter(Mandatory)]
        [string]$File 
    )
 
    try {
        $syncTable = [hashtable]::Synchronized(@{})
        $syncTable.Close = $false

        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = "STA"
        $runspace.ThreadOptions = "ReuseThread"
        $runspace.Name = "BiomeUpdater"
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable("syncTable", $syncTable)

        $scriptBlock = [scriptblock]::Create({

                [xml]$xaml = 
                @"    
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Biome Updater" 
        Height="100" 
        Width="300" 
        ResizeMode="NoResize">
   <Grid Margin="5,5,5,5">
     <Grid.ColumnDefinitions>
       <ColumnDefinition />
     </Grid.ColumnDefinitions>
     <Grid.RowDefinitions>
       <RowDefinition />
       <RowDefinition />
     </Grid.RowDefinitions>
     <ProgressBar Grid.Row="0" Grid.Column="0" Width="200" Height="40" Name="progressBar"></ProgressBar>
     <Label Name="progressLabel" Content="Staring..." Grid.Row="1" Grid.Column="0" Margin="35,0,0,0"/>
  </Grid>
</Window>
"@ 
                $xamlReader = (New-Object System.Xml.XmlNodeReader $xaml)
                $window = [Windows.Markup.XamlReader]::Load( $xamlReader );

                $progressBar = $window.FindName("progressBar")
                $label = $window.FindName("progressLabel")
                $syncTable.Window = $window
                $syncTable.ProgressBar = $progressBar
                $syncTable.Label = $label
          
                $window.Add_Closing({
                        param($Sender, $Exit)
                        $syncTable.Close = $true
                    })

                $window.ShowDialog() | Out-Null

                $syncTable.Window = $null
            })
        
        $pipe = $runspace.CreatePipeline($scriptBlock)
        $pipe.InvokeAsync()
        
        Start-Sleep -Seconds 2

        $storeEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'

        # invoke request
        $request = [System.Net.HttpWebRequest]::Create($URL)
        $response = $request.GetResponse()

        if ($response.StatusCode -eq 401 -or $response.StatusCode -eq 403 -or $response.StatusCode -eq 404) {
            throw "Remote file either doesn't exist, is unauthorized, or is forbidden for '$URL'."
        }

        if ($File -match '^\.\\') {
            $File = Join-Path (Get-Location -PSProvider "FileSystem") ($File -Split '^\.')[1]
        }
            
        if ($File -and !(Split-Path $File)) {
            $File = Join-Path (Get-Location -PSProvider "FileSystem") $File
        }

        if ($File) {
            $fileDirectory = $([System.IO.Path]::GetDirectoryName($File))
            if (!(Test-Path($fileDirectory))) {
                [System.IO.Directory]::CreateDirectory($fileDirectory) | Out-Null
            }
        }

        [long]$fullSize = $response.ContentLength
        $fullSizeMB = $fullSize / 1024 / 1024
  
        # define buffer
        [byte[]]$buffer = new-object byte[] 1048576
        [long]$total = [long]$count = 0

        # create reader / writer
        $reader = $response.GetResponseStream()
        $writer = new-object System.IO.FileStream $File, "Create"

        $frame = 0

        do {
            if ($syncTable.Close -eq $true) {
                break
            }
           
            $frame++
            $count = $reader.Read($buffer, 0, $buffer.Length)
            $writer.Write($buffer, 0, $count)
              
            $total += $count
            $totalMB = $total / 1024 / 1024

            $percent = $totalMB / $fullSizeMB
            $percentComplete = $percent * 100

            if ($frame -gt 12) {
                $frame = 0
                if (-not $syncTable.Window -eq $null) {
                    $syncTable.Window.Dispatcher.Invoke([Action] {
                            $syncTable.ProgressBar.Value = $percentComplete
                            $syncTable.Label.Content = "Progress: $([math]::Round($totalMB,2))MB Of $([math]::Round($fullSizeMB,2))MB"
                        }, "Background")
                }
            }                 
        } while ($count -gt 0)

        Write-Debug "Finished downloading"

        return -not $syncTable.Close
    }
    catch {
        $ExceptionMsg = $_.Exception.Message
        Write-Error "Download breaks with error : $ExceptionMsg"
        return $false
    }
    finally {
        # cleanup
        Write-Debug "Cleanup reader/writer"
        if ($reader) { $reader.Close() }
        if ($writer) { $writer.Flush(); $writer.Close() }
        
        $ErrorActionPreference = $storeEAP
        Write-Debug "GC"
        [GC]::Collect()
        Write-Debug "Close Window if Needed"
        if (-not $syncTable.Window -eq $null) {
            $syncTable.Window.Dispatcher.Invoke([Action] {
                    $syncTable.Window.Close()
                })
        }
        $runspace.Dispose()
    }    
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

        $finished = Get-FileFromWeb -URL $item.browser_download_url -File $outfile

        if (-not $finished) {
            throw 'Did not finished downloading'
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
    $latestVersion = $content.tag_name.Replace("@biomejs/biome@", "")

    Write-Host "Latest git tag found $($latestVersion)"

    return @{
        Content = $content
        Version = $latestVersion
    }
}
$exitCode = 0
try {
    $biomeFolder = Join-Path -Path $env:USERPROFILE -ChildPath "/biome"
    $biomeExe = Join-Path -Path $biomeFolder -ChildPath "biome.exe"

    if (-not (Test-Path -Path $biomeFolder)) {
        mkdir $biomeFolder
    }

    Start-Transcript -Path "$(Join-Path -Path $biomeFolder -ChildPath 'updater.log')" -Append -NoClobber
    Install-Task -ScriptFolder $biomeFolder -Script 'biome-updater.ps1'

    if (!(Get-Command biome.exe -ErrorAction SilentlyContinue)) {
        $latest = Get-LatestVersion
        if ($null -eq $latest) {
            throw 'Failed to fetch latest biome version from github'
        }

        $result = [System.Windows.Forms.MessageBox]::Show(
            "Biome has version ${$latest.Version} (Current 'None') Would you like to Install?", 
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
    $cliOutput = biome --version
    $currentBiomeVersion = $cliOutput.Replace("Version: ", "")#>

    Write-Host "Installed Biome Version: $($currentBiomeVersion)"
    Write-Host "Install directory: $($biomeFolder)"

    $latest = Get-LatestVersion

    if ($null -eq $latest) {
        throw 'Failed to fetch latest biome version from github'
    }

    if ($latest.Version -eq $currentBiomeVersion) {
        Write-Host "Biome is at latest" 
        return
    }

    $result = [System.Windows.Forms.MessageBox]::Show(
        "Biome has version ${$latest.Version} (Current ${currentBiomeVersion}) Would you like to Update?", 
        "Biome update", 
        [System.Windows.Forms.MessageBoxButtons]::OKCancel)

    if (!($result -eq [System.Windows.Forms.DialogResult]::Ok)) {
        Write-Host "Update was declined"
        return
    }#
    Install-Biome -Content $latest.Content
}
catch {
    Write-Error $_.Exception.Message
    $exitCode = 1
}
finally {
    Stop-Transcript
    exit $exitCode
}
