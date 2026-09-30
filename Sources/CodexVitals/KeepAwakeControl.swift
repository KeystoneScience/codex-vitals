import SwiftUI
import Combine

struct KeepAwakeControl: View {
    @ObservedObject var controller: KeepAwakeController
    @State private var showingOptions = false
    private let statusTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Button {
            controller.refreshSystemState()
            showingOptions.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(controller.isConfirmedOn ? Theme.healthyAccent : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(controller.label)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(controller.isConfirmedOn ? Theme.healthyAccent : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(controller.isConfirmedOn ? Theme.healthyAccent.opacity(0.09) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("\(controller.label). Choose a timer or Never, or turn it off.")
        .accessibilityLabel(controller.label)
        .onAppear { controller.refreshSystemState() }
        .onReceive(statusTimer) { _ in controller.refreshSystemState() }
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            KeepAwakeOptions(controller: controller).padding(18).frame(width: 350)
        }
    }
}

struct KeepAwakeOptions: View {
    @ObservedObject var controller: KeepAwakeController
    @State var minutes = 60
    @State private var customMinutes = 90

    private var selectedMinutes: Int { minutes == -1 ? customMinutes : minutes }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep awake").font(.system(size: 15, weight: .semibold))
            Label(controller.statusText, systemImage: controller.isConfirmedOn ? "checkmark.circle.fill" : "moon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(controller.isConfirmedOn ? Theme.healthyAccent : .secondary)
            Text("Keep work running with the lid closed.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("The built-in screen dims when you close the lid and returns to its previous brightness when you reopen it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = controller.brightnessWarning {
                Text(warning).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.canStart {
                Picker("Auto-off", selection: $minutes) {
                    Text("Never").tag(0)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                    Text("4 hours").tag(240)
                    Text("8 hours").tag(480)
                    Text("12 hours").tag(720)
                    Text("Custom…").tag(-1)
                }
                if minutes == -1 {
                    HStack {
                        Text("Minutes")
                        TextField("Minutes", value: $customMinutes, format: .number.grouping(.never))
                            .frame(width: 65)
                        Stepper("Minutes", value: $customMinutes, in: 1...720).labelsHidden()
                    }
                }
                if selectedMinutes == 0 {
                    Text("No timer. Stays on until you turn it off or Headroom closes.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        Text("Auto-off at \(ResetFormatter.timeText(timeline.date.addingTimeInterval(Double(selectedMinutes) * 60))).")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Button("Start keep awake") { controller.start(minutes: selectedMinutes) }
                    .buttonStyle(.borderedProminent)
                    .disabled(minutes == -1 ? !(1...720).contains(customMinutes) : !(0...720).contains(minutes))
                Text("macOS will ask for administrator approval.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if controller.phase != .off {
                if let deadline = controller.deadline {
                    Text("Turns off \(ResetFormatter.fullTooltip(date: deadline))")
                        .font(.system(size: 12, weight: .medium))
                } else if controller.phase == .active {
                    Text("Auto-off: Never. Turn it off here whenever you’re done.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                if controller.phase == .starting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(controller.startingDetail).font(.system(size: 12))
                    }
                } else if controller.phase == .stopping {
                    Text("Restoring normal sleep…").font(.system(size: 12))
                }
                Button(controller.phase == .starting ? "Cancel" : "Turn off now") { controller.stop() }
                    .disabled(controller.phase == .stopping)
            } else {
                Text(controller.isConfirmedOn
                     ? "Sleep is already disabled outside this Headroom session. Manage it in the app that enabled it."
                     : "Unable to read the Mac’s sleep setting.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check status") { controller.refreshSystemState() }
            }

            if let message = controller.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Also stops when Headroom closes or the battery reaches 15%. Keep your Mac on a ventilated surface.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
