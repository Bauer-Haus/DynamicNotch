//
//  MusicSliderView.swift
//  DynamicNotch
//
//  The draggable progress bar used by the playback progress row.
//

import AVKit
import Combine
import Defaults
import SwiftUI

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var onValueChange: (Double) -> Void


    var body: some View {
        HStack(spacing: OpenPlayer.timeToBar) {
            Text(timeString(from: sliderValue))
                .monospacedDigit()
            CustomSlider(
                value: $sliderValue,
                range: 0...duration,
                // The played part is the same grey as the times either side of it.
                color: .gray,
                dragging: $dragging,
                lastDragged: $lastDragged,
                onValueChange: onValueChange,
                thickness: OpenPlayer.barThickness
            )
            // Apple's bar sits a little below the middle of the times.
            .offset(y: OpenPlayer.barDrop)
            // Time left, as on the iPhone (-3:49).
            Text("−" + timeString(from: max(0, duration - sliderValue)))
                .monospacedDigit()
        }
        .font(.system(size: OpenPlayer.timeSize, weight: .medium))
        .foregroundColor(.gray)
        .onChange(of: currentDate) {
           guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
            sliderValue = MusicManager.shared.estimatedPlaybackPosition(at: currentDate)
        }
        // The timeline is paused while music is paused; still follow seeks and track changes.
        .onChange(of: elapsedTime) {
            guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
            sliderValue = MusicManager.shared.estimatedPlaybackPosition()
        }
    }

    func timeString(from seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?
    /// Bar thickness at rest; it grows by 4 pt while dragged.
    var thickness: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = dragging ? thickness + 4 : thickness
            let rangeSpan = range.upperBound - range.lowerBound

            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: height)

                Rectangle()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: height)
            }
            .cornerRadius(height / 2)
            .frame(height: thickness + 5)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation {
                            dragging = true
                        }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dragging)
        }
    }
}
