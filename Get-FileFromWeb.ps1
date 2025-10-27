param (
  [string]$Url,
  [string]$File
)

Add-Type -AssemblyName PresentationFramework


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

Get-FileFromWeb -Url $Url -File $File
