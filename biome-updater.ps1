Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

#if (!(Get-Command biome.exe -ErrorAction SilentlyContinue)) {
 #   Write-Error "biome is not in the current path"
 #   return 
#} else {


#}
#$cliOutput = biome --version
#$currentBiomeVersion = $cliOutput.Replace("Version: ", "")
#$biomeFolder = Join-Path -Path $env:USERPROFILE -ChildPath "/biome"
#$biomeExe = Join-Path -Path $biomeFolder -ChildPath "biome.exe"

#Write-Verbose "Installed Biome $($currentBiomeVersion)"
#Write-Verbose "Install directory $($biomeFolder)"

function Remove-File {
    param (
        $Path
    )

    if (Test-Path -Path $Path) {
        Remove-Item -Path $Path -Force
    }
}

# https://gist.github.com/ChrisStro/37444dd012f79592080bd46223e27adc
function Invoke-WebRequest-With-Progress {
    param (
        [Parameter(Mandatory)]
        [string]$OutFile,
        [Parameter(Mandatory)]
        [string]$Url
    )
    try {
            [xml]$xaml = 
            @"    
                <Window
                    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                     Title="Biome Updater" Height="100" Width="300" ResizeMode="NoResize">
                        <Grid Margin="5,5,5,5">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition />
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition />
                                <RowDefinition />
                            </Grid.RowDefinitions>
                            <ProgressBar Grid.Row="0"  Grid.Column="0" Width="200" Height="40"
                                    Name="progressBar">
                            </ProgressBar>
                            <Label Name="progressLabel" Content="Staring..." Grid.Row="1" Grid.Column="0" Margin="35,0,0,0"/>
                        </Grid>
                </Window>
"@          
            $xamlReader = (New-Object System.Xml.XmlNodeReader $xaml)
            $window = [Windows.Markup.XamlReader]::Load( $xamlReader );

            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.Open()
            $runspace.SessionStateProxy.SetVariable("window", $window)
            $runspace.SessionStateProxy.SetVariable("File", $OutFile)
            $runspace.SessionStateProxy.SetVariable("Url", $Url)
            $scriptBlock = [scriptblock]::Create({
                    Start-Sleep -Seconds 1
                    try {
                        $storeEAP = $ErrorActionPreference
                        $ErrorActionPreference = 'Stop'
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

                        [long]$fullSize = $response.ContentLength
                        $fullSizeMB = $fullSize / 1024 / 1024

                        [byte[]]$buffer = new-object byte[] 1048576
                        [long]$total = [long]$count = 0

                        $reader = $response.GetResponseStream()
                        $writer = new-object System.IO.FileStream $File, "Create"

                        $progressBar = $window.FindName("progressBar")
                        $label = $window.FindName("progressLabel")
                        $finalBarCount = 0 #show final bar only one time
                        do {
          
                            $count = $reader.Read($buffer, 0, $buffer.Length)
          
                            $writer.Write($buffer, 0, $count)
              
                            $total += $count
                            $totalMB = $total / 1024 / 1024

                            $percent = $CurrentValue / $TotalValue
                            $percentComplete = $percent * 100
          
                            if ($fullSize -gt 0) {
                                $window.Dispatcher.Invoke([Action] {
                                        $progressBar.Value = $percentComplete
                                        $label.Content = "Downloading $($File.Name) $( ([math]::Round($totalMB) / 1MB) )/$($fullSizeMB)"
                                    });
                            }

                            if ($total -eq $fullSize -and $count -eq 0 -and $finalBarCount -eq 0) {
                                $window.Dispatcher.Invoke([Action] {
                                        $progressBar.Value = $percentComplete
                                        $label.Content = "Downloading $($File.Name) $($totalMB)/$($fullSizeMB)"
                                    });

                                $finalBarCount++
                                #Write-Host "$finalBarCount"
                            }

                        } while ($count -gt 0)
                    }
                    catch {
                        $ExceptionMsg = $_.Exception.Message
                        Write-Host "Download breaks with error : $ExceptionMsg"
                    }
                    finally {
                        # cleanup
                        if ($reader) { $reader.Close() }
                        if ($writer) { $writer.Flush(); $writer.Close() }
        
                        $ErrorActionPreference = $storeEAP
                        [GC]::Collect()
                        
                    }
                })
            $runspace.CreatePipeline($scriptBlock).InvokeAsync()

            $window.ShowDialog() | Out-Null
        }
        catch [System.Management.Automation.MethodInvocationException] {
            Write-Error "We ran into a problem with the XAML code.  Check the syntax for this control..." -ForegroundColor Red
            Write-Error $error[0].Exception.Message -ForegroundColor Red
        }
        catch {
            $ExceptionMsg = $_.Exception.Message
            Write-Error $ExceptionMsg
        }
        finally {
            $runspace.Dispose()
        }
}

function Install-Biome {
    param (
        $Content
    )

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

    Invoke-WebRequest-With-Progress -Url $item.browser_download_url -OutFile $outfile

    $result = Get-FileHash -Path $outfile -Algorithm $alg

    if (!($hash -eq $result.Hash)) {
        Write-Error "file hash did not match download file! Was expecting '$($hash)' but got '$($result.Hash)'"
        return
    }

    if (Test-Path -Path $biomeExe) {
        Remove-Item -Path $biomeExe -Force
    }

    Rename-Item -Path $outfile -NewName "biome.exe"
}

function Get-Latest-Version {
    Write-Verbose "Fetching latest biome version"
    $response = Invoke-WebRequest "https://api.github.com/repos/biomejs/biome/releases/latest"

    if (!($response.StatusCode -eq 200)) {
        Write-Error Got a $response.StatusCode status code
        return null;
    }

    $content = $response.Content | ConvertFrom-Json
    $latestVersion = $content.tag_name.Replace("@biomejs/biome@", "")

    return @{
        Content = $content
        Version = $latestVersion
    }
}


#$latest = Get-Latest-Version
#if (!($latest.Version -eq $currentBiomeVersion)) {
#    Write-Host "Biome is at latest" 
#    return 
#}

#$result = [System.Windows.Forms.MessageBox]::Show(
#"Biome has version ${$latest.Version} (Current ${currentBiomeVersion}) Would you like to Update?", 
#"Biome update", 
#    [System.Windows.Forms.MessageBoxButtons]::OKCancel)
#if (!($result -eq [System.Windows.Forms.DialogResult]::Ok)) {
#    Write-Host "Update was declined"
#    return
#}

#Write-Verbose "Updating to biome version $($latest.Version)"
#Install-Biome -Content $latest.Content

 Invoke-WebRequest-With-Progress -Url "https://samples-files.com/samples/code/json/sample1.json" -OutFile "C:\Users\User\biome\sample1.json"
