using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.IO;
using System.Windows;
using System.Windows.Markup;

public static class StreamExtensions
{
    public static async Task CopyToAsync(this Stream stream, Stream destination, int bufferSize, IProgress<long> progress, CancellationToken cancellationToken)
    {
        if (stream == null) throw new ArgumentException("stream is null");
        if (!stream.CanRead) throw new ArgumentException("can not read");
        if (destination == null) throw new ArgumentException("destination is null");
        if (!destination.CanWrite) throw new ArgumentException("can not write");
        if (bufferSize < 0) throw new ArgumentOutOfRangeException("buffer size must be more then 0");

        var buffer = new byte[bufferSize];
        long totalBytesRead = 0;
        int bytesRead;
        while ((bytesRead = await stream.ReadAsync(buffer, 0, buffer.Length, cancellationToken)) > 0)
        {
            await destination.WriteAsync(buffer, 0, bytesRead, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            totalBytesRead += bytesRead;
            progress.Report(totalBytesRead);
        }
    }
}

public static class HttpClientExtensions
{
    public static async Task DownloadAsync(this HttpClient client, string uri, Stream destination, IProgress<float> progress, CancellationToken cancellationToken)
    {
        using (var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead))
        {
            var contentLength = response.Content.Headers.ContentLength;
            using (var download = await response.Content.ReadAsStreamAsync(cancellationToken))
            {
                if (progress == null || !contentLength.HasValue)
                {
                    await download.CopyToAsync(destination);
                    return;
                }

                var relativeProgress = new Progress<long>(totalBytes => progress.Report((float)totalBytes / contentLength.Value));
                await download.CopyToAsync(destination, 81920, relativeProgress, cancellationToken);
            }
        }
    }
}

namespace BiomeUpdater
{
    public class FileHandler : Application
    {
        private CancellationTokenSource source = new CancellationTokenSource();
        private IProgress<float> progress = null;

        private Window window;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            string xaml = @"
                <Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
                    xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
                    Title='Biome Updater' 
                    Height='100'
                    Width='300' 
                    ResizeMode='NoResize'>
                    <Grid Margin='5,5,5,5'>
                        <Grid.ColumnDefinitions>
                        <ColumnDefinition />
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                        <RowDefinition />
                        <RowDefinition />
                        </Grid.RowDefinitions>
                        <ProgressBar Grid.Row='0' Grid.Column='0' Width='200' Height='40' Name='progressBar'></ProgressBar>
                        <Label Name='progressLabel' Content='Staring...' Grid.Row='1' Grid.Column='0' Margin='35,0,0,0'/>
                    </Grid>
            </Window>
            ";

            window = (Window)XamlReader.Parse(xaml);

            window.Closed += (object sender, System.EventArgs e) =>
            {
                Cancel();
            };

            var progressBar = (System.Windows.Controls.ProgressBar)window.FindName("progressBar");
            var progressLabel = (System.Windows.Controls.Label)window.FindName("progressLabel");

            SetProgress((value) =>
            {
                Application.Current.Dispatcher.BeginInvoke(() =>
                {
                    float norm = value / 1;

                    progressBar.Value += norm * 100;
                    progressLabel.Content = $"{value} of 1";
                });
            });

            window.Show();
        }

        [STAThread]
        public static void Main(string[] args)
        {
            if (args.Length < 3) throw new ArgumentOutOfRangeException("expected 3 args");

            string url = args[1];
            string path = args[2];

            var app = new FileHandler();

            var thread = new Thread(() =>
            {
                Thread.Sleep(2000);

                Task.Run(() => app.StartDownload(url, path)).Wait();

                Thread.Sleep(2000);

                Application.Current.Dispatcher.Invoke(() =>
                {
                    app.window.Close();
                });
            });

            thread.Start();
            app.Run();
        }
        public void SetProgress(Action<float> callback)
        {
            progress = new Progress<float>(callback);
        }

        public void Cancel()
        {
            source.Cancel();
        }

        public async Task StartDownload(string url, string path)
        {
            CancellationToken cancellationToken = source.Token;

            using (var client = new HttpClient())
            {
                client.Timeout = TimeSpan.FromMinutes(10);
                using (var file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    await client.DownloadAsync(url, file, progress, cancellationToken);
                }
            }
        }
    }
}
