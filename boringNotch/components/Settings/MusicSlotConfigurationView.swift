//
//  MusicSlotConfigurationView.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-17.
//

import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct MusicSlotConfigurationView: View {
    @Default(.musicControlSlots) private var musicControlSlots
    @ObservedObject private var musicManager = MusicManager.shared
    @State private var draggedSlot: MusicControlButton?

    private let fixedSlotCount: Int = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Slot configuration (fixed 5)
            slotConfigurationSection

            // Reset button
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    withAnimation {
                        musicControlSlots = MusicControlButton.defaultLayout
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .onAppear {
            ensureSlotCapacity(fixedSlotCount)
        }
    }

    private var previewSection: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<fixedSlotCount, id: \.self) { index in
                    let slot = slotValue(at: index)
                    Group {
                        if slot != .none {
                            slotPreview(for: slot)
                                .frame(maxWidth: 44)
                                .onDrag {
                                    // remember what's being dragged for UX
                                    DispatchQueue.main.async { draggedSlot = slot }
                                    return NSItemProvider(object: NSString(string: "slot:\(index)"))
                                }
                                .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                                    let handled = handleDrop(providers, toIndex: index)
                                    // clear drag state
                                    DispatchQueue.main.async { draggedSlot = nil }
                                    return handled
                                }
                        } else {
                            // empty slot: allow drops but do not allow dragging
                            slotPreview(for: slot)
                                .frame(maxWidth: 44)
                                .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                                    let handled = handleDrop(providers, toIndex: index)
                                    DispatchQueue.main.async { draggedSlot = nil }
                                    return handled
                                }
                        }
                    }
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .frame(width: 56, height: 56)

                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.primary)
                }
                .cornerRadius(10)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                    return handleDropOnTrash(providers)
                }

                Text("Clear slot")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 72)
            }
        }
    }

    private var slotConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layout Preview")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Drag items in the preview to reorder or drop from the palette")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            previewSection

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Drag a control onto a slot")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(MusicControlButton.pickerOptions, id: \.self) { control in
                            VStack(spacing: 6) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(NSColor.controlBackgroundColor))
                                        .frame(width: 44, height: 44)

                                    if control != .none {
                                        Image(systemName: control.iconName)
                                            .font(.system(size: control.prefersLargeScale ? 18 : 15, weight: .medium))
                                            .foregroundStyle(control == .none ? Color.secondary : Color.primary)
                                            .frame(width: 28, height: 28)
                                    }
                                }
                                .cornerRadius(8)
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                                .onDrag {
                                    return NSItemProvider(object: NSString(string: "control:\(control.rawValue)"))
                                }
                                .onTapGesture {
                                    if let idx = musicControlSlots.firstIndex(of: .none) {
                                        updateSlot(control, at: idx)
                                    } else {
                                        withAnimation { updateSlot(control, at: 0) }
                                    }
                                }

                                Text(control.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private func slotConfigRow(for index: Int) -> some View {
        let currentSlot = slotValue(at: index)

        return HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Group {
                if currentSlot != .none {
                    slotPreview(for: currentSlot)
                        .frame(height: 32)
                        .onDrag {
                            DispatchQueue.main.async { draggedSlot = currentSlot }
                            return NSItemProvider(object: NSString(string: "slot:\(index)"))
                        }
                        .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                            let handled = handleDrop(providers, toIndex: index)
                            DispatchQueue.main.async { draggedSlot = nil }
                            return handled
                        }
                } else {
                    // empty slot: allow drops but not dragging
                    slotPreview(for: currentSlot)
                        .frame(height: 32)
                        .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                            let handled = handleDrop(providers, toIndex: index)
                            DispatchQueue.main.async { draggedSlot = nil }
                            return handled
                        }
                }
            }

            Spacer()
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func slotPreview(for slot: MusicControlButton) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .frame(width: 44, height: 44)

            if slot != .none {
                Image(systemName: slot.iconName)
                    .font(.system(size: slot.prefersLargeScale ? 18 : 15, weight: .medium))
                    .foregroundStyle(previewIconColor(for: slot))
                    .frame(width: 28, height: 28)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .frame(width: 32, height: 32)
            }
        }
        .cornerRadius(8)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func previewIconColor(for slot: MusicControlButton) -> Color {
        switch slot {
        case .shuffle:
            return musicManager.isShuffled ? .systemAccent : .primary
        case .repeatMode:
            return musicManager.repeatMode != .off ? .systemAccent : .primary
        case .favorite:
            return musicManager.isFavoriteTrack ? .systemAccent : .primary
        case .playPause:
            return .primary
        default:
            return .primary
        }
    }

    private func ensureSlotCapacity(_ target: Int) {
        guard target > musicControlSlots.count else { return }
        let missing = target - musicControlSlots.count
        musicControlSlots.append(contentsOf: Array(repeating: .none, count: missing))
    }

    private func slotBinding(for index: Int) -> Binding<MusicControlButton> {
        Binding(
            get: { slotValue(at: index) },
            set: { newValue in updateSlot(newValue, at: index) }
        )
    }

    private func slotValue(at index: Int) -> MusicControlButton {
        guard musicControlSlots.indices.contains(index) else { return .none }
        return musicControlSlots[index]
    }

    /// Reads the dragged text ("slot:3" or "control:shuffle") and hands it over on the main
    /// thread. False if nothing in the drop is text.
    private func loadDraggedText(_ providers: [NSItemProvider], then handle: @escaping (String) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        provider.loadObject(ofClass: NSString.self) { item, _ in
            // item may be an NSString or another reading type
            guard let text = (item as? NSString).map({ $0 as String }) ?? (item as? String) else { return }
            DispatchQueue.main.async { handle(text) }
        }
        return true
    }

    /// The slot a dragged "slot:<index>" came from, if it is a real slot.
    private func draggedSlot(_ text: String) -> Int? {
        guard text.hasPrefix("slot:"), let from = Int(text.dropFirst("slot:".count)),
              from >= 0, from < fixedSlotCount, from < musicControlSlots.count else { return nil }
        return from
    }

    private func handleDrop(_ providers: [NSItemProvider], toIndex: Int) -> Bool {
        loadDraggedText(providers) { processDropString($0, toIndex: toIndex) }
    }

    private func handleDropOnTrash(_ providers: [NSItemProvider]) -> Bool {
        loadDraggedText(providers) { text in
            guard let from = draggedSlot(text) else { return }
            var slots = musicControlSlots
            slots[from] = .none
            musicControlSlots = slots
        }
    }

    private func processDropString(_ raw: String, toIndex: Int) {
        if raw.hasPrefix("slot:") {
            guard let from = draggedSlot(raw), toIndex < musicControlSlots.count else { return }
            var slots = musicControlSlots
            slots.swapAt(from, toIndex)
            musicControlSlots = slots
        } else if raw.hasPrefix("control:") {
            let val = raw.replacingOccurrences(of: "control:", with: "")
            if let control = MusicControlButton(rawValue: val) {
                // If this control already exists in another slot, clear that original slot
                var slots = musicControlSlots
                if let existing = slots.firstIndex(of: control), existing != toIndex {
                    slots[existing] = .none
                    musicControlSlots = slots
                }

                updateSlot(control, at: toIndex)
            }
        }
    }

    private func updateSlot(_ value: MusicControlButton, at index: Int) {
        var slots = musicControlSlots
        if index >= slots.count {
            slots.append(contentsOf: Array(repeating: .none, count: index - slots.count + 1))
        }
        slots[index] = value
        musicControlSlots = slots
    }
}
