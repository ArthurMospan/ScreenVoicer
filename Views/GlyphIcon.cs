using System;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace ScreenVoicer.Views
{
    /// <summary>
    /// One of the app's line icons (the "Icon.*" geometries in App.xaml, drawn on a 24-unit grid) stroked with
    /// round caps in the inherited foreground, so a button's hover/disabled colours apply to it like to text.
    /// </summary>
    public sealed class GlyphIcon : FrameworkElement
    {
        private const double Grid = 24;

        public static readonly DependencyProperty DataProperty = DependencyProperty.Register(
            nameof(Data), typeof(Geometry), typeof(GlyphIcon),
            new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

        public static readonly DependencyProperty ForegroundProperty = TextElement.ForegroundProperty.AddOwner(
            typeof(GlyphIcon),
            new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.Inherits | FrameworkPropertyMetadataOptions.AffectsRender));

        public static readonly DependencyProperty StrokeThicknessProperty = DependencyProperty.Register(
            nameof(StrokeThickness), typeof(double), typeof(GlyphIcon),
            new FrameworkPropertyMetadata(1.9, FrameworkPropertyMetadataOptions.AffectsRender));

        public Geometry? Data
        {
            get => (Geometry?)GetValue(DataProperty);
            set => SetValue(DataProperty, value);
        }

        public Brush Foreground
        {
            get => (Brush)GetValue(ForegroundProperty);
            set => SetValue(ForegroundProperty, value);
        }

        /// <summary>In grid units: 1.9 is ~1.4 px at the usual 18 px size.</summary>
        public double StrokeThickness
        {
            get => (double)GetValue(StrokeThicknessProperty);
            set => SetValue(StrokeThicknessProperty, value);
        }

        public GlyphIcon()
        {
            Width = 18;
            Height = 18;
            SnapsToDevicePixels = true;
            VerticalAlignment = VerticalAlignment.Center;
            HorizontalAlignment = HorizontalAlignment.Center;
        }

        protected override Size MeasureOverride(Size availableSize) => new(Width, Height);

        protected override void OnRender(DrawingContext dc)
        {
            var data = Data;
            if (data == null || ActualWidth <= 0 || ActualHeight <= 0)
            {
                return;
            }

            double scale = Math.Min(ActualWidth, ActualHeight) / Grid;
            var pen = new Pen(Foreground, StrokeThickness)
            {
                StartLineCap = PenLineCap.Round,
                EndLineCap = PenLineCap.Round,
                LineJoin = PenLineJoin.Round
            };
            pen.Freeze();

            dc.PushTransform(new TranslateTransform((ActualWidth - Grid * scale) / 2, (ActualHeight - Grid * scale) / 2));
            dc.PushTransform(new ScaleTransform(scale, scale));
            dc.DrawGeometry(null, pen, data);
            dc.Pop();
            dc.Pop();
        }
    }
}
