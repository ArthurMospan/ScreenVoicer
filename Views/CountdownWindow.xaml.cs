using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace ScreenVoicer.Views
{
    public partial class CountdownWindow : Window
    {
        private bool _cancelled;
        private bool _closed;

        public CountdownWindow()
        {
            InitializeComponent();
            Loaded += OnLoaded;
            Closed += (_, _) => _closed = true;
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            var workArea = SystemParameters.WorkArea;
            Left = workArea.Left + (workArea.Width - ActualWidth) / 2;
            Top = workArea.Top + 24;
            BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160)));

            var pulse = new DoubleAnimation(1, 1.6, TimeSpan.FromMilliseconds(500)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever };
            PulseScale.BeginAnimation(ScaleTransform.ScaleXProperty, pulse);
            PulseScale.BeginAnimation(ScaleTransform.ScaleYProperty, pulse);
        }

        /// <summary>Counts down and closes itself. Returns false if the user clicked to cancel.</summary>
        public async Task<bool> RunAsync(int seconds)
        {
            Show();
            for (int i = seconds; i > 0 && !_cancelled; i--)
            {
                TxtSeconds.Text = i.ToString();
                await Task.Delay(1000);
            }

            if (!_closed)
            {
                Close();
            }
            return !_cancelled;
        }

        private void OnClick(object sender, MouseButtonEventArgs e)
        {
            _cancelled = true;
            if (!_closed)
            {
                Close();
            }
        }
    }
}
