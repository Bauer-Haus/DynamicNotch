//
//  ControlRowEditor.swift
//  DynamicNotch
//
//  The editor for the open player's row of controls: the row as it looks in the notch, where
//  clicking a button lets you swap, move or remove it.
//

import Defaults
import SwiftUI

struct ControlRowEditor: View {
    @Default(.musicControlSlots) private var config
    /// The button whose menu is open (`controls.count` for the add button).
    @State private var editing: Int?

    /// The buttons in the row, in order, as the player shows them.
    private var controls: [MusicControlButton] {
        MusicControlsView.shownSlots(config, limit: MusicControlButton.maxSlotCount)
    }

    private var canAdd: Bool { controls.count < MusicControlButton.maxSlotCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SettingsLabel(
                    "Controls",
                    subtitle: "Click a button to change, move or remove it.",
                    symbol: "slider.horizontal.3", color: .pink)
                Spacer()
                Button("Reset") { save(MusicControlButton.defaultLayout.filter { $0 != .none }) }
                    .disabled(controls == MusicControlButton.defaultLayout.filter { $0 != .none })
            }

            HStack(spacing: 4) {
                ForEach(Array(controls.enumerated()), id: \.offset) { index, control in
                    slot(index: index) {
                        // Play/pause as the playing player shows it.
                        Image(systemName: control == .playPause ? "pause.fill" : control.iconName)
                            .font(.system(size: control.prefersLargeScale ? 22 : 17, weight: .semibold))
                            .foregroundStyle(.white)
                    } menu: {
                        menu(for: index)
                    }
                }
                if canAdd {
                    slot(index: controls.count) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    } menu: {
                        choices(replacing: nil)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black)
            )
        }
        .padding(.vertical, 4)
    }

    /// One place in the row: a button that opens its menu in a popover.
    private func slot<Icon: View, Menu: View>(
        index: Int, @ViewBuilder icon: () -> Icon, @ViewBuilder menu: @escaping () -> Menu
    ) -> some View {
        let isOpen = Binding(
            get: { editing == index },
            set: { if !$0 { editing = nil } })
        return Button { editing = index } label: {
            icon()
                .frame(width: 52, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(editing == index ? 0.18 : 0.0001))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) { menu() }
                .padding(8)
                .frame(width: 220)
        }
    }

    @ViewBuilder
    private func menu(for index: Int) -> some View {
        if index > 0 {
            menuButton("Move left", symbol: "arrow.left") { move(index, by: -1) }
        }
        if index < controls.count - 1 {
            menuButton("Move right", symbol: "arrow.right") { move(index, by: 1) }
        }
        menuButton("Remove", symbol: "minus.circle", role: .destructive) {
            var list = controls
            list.remove(at: index)
            save(list)
        }
        .disabled(controls.count <= 1)
        Divider().padding(.vertical, 4)
        choices(replacing: index)
    }

    /// Every control not already in the row; picking one puts it at `index` (or adds it).
    @ViewBuilder
    private func choices(replacing index: Int?) -> some View {
        let unused = MusicControlButton.pickerOptions.filter { !controls.contains($0) }
        if unused.isEmpty {
            Text("Every control is in the row.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
        ForEach(unused) { control in
            menuButton(LocalizedStringKey(control.label), symbol: control.iconName) {
                var list = controls
                if let index { list[index] = control } else { list.append(control) }
                save(list)
            }
        }
    }

    private func menuButton(
        _ title: LocalizedStringKey, symbol: String, role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role) {
            action()
            editing = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 20)
                Text(title)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    private func move(_ index: Int, by offset: Int) {
        var list = controls
        list.swapAt(index, index + offset)
        save(list)
    }

    /// Saves the row, padded with empty slots to the full count as before.
    private func save(_ list: [MusicControlButton]) {
        let count = MusicControlButton.maxSlotCount
        withAnimation(.snappy) {
            config = Array(list.prefix(count)) + Array(repeating: .none, count: max(0, count - list.count))
        }
    }
}

/// A menu-like row that highlights under the pointer.
private struct MenuRowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering || configuration.isPressed ? Color.primary.opacity(0.1) : .clear)
            )
            .onHover { hovering = $0 }
    }
}
