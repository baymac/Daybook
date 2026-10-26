import SwiftUI

private let dateAccent = Paper.teal

struct DateNavigator: View {
  @Binding var selection: Date
  var step = 1
  @State private var showingCalendar = false
  private var calendar: Calendar { .current }
  private var isToday: Bool { calendar.isDateInToday(selection) }

  var body: some View {
    HStack(spacing: 6) {
      arrow("chevron.left", label: step == 7 ? "Previous week" : "Previous day") { move(-step) }
      Button {
        showingCalendar.toggle()
      } label: {
        HStack(spacing: 10) {
          Image(systemName: "calendar").foregroundStyle(dateAccent)
          Text(selection.formatted(.dateTime.month(.abbreviated).day().year()))
            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
          Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).opacity(0.55)
        }.padding(.horizontal, 14).frame(minWidth: 188, minHeight: 44).contentShape(Rectangle())
      }
      .buttonStyle(DateControlStyle()).help("Choose a date")
      .accessibilityLabel("Choose date, \(selection.formatted(date: .complete, time: .omitted))")
      .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
        DayCalendar(selection: $selection) { showingCalendar = false }
      }
      arrow("chevron.right", label: step == 7 ? "Next week" : "Next day") { move(step) }
        .disabled(isToday)
      Button {
        selection = Date()
      } label: {
        Text("Today").font(.system(size: 12, weight: .semibold))
          .padding(.horizontal, 14).frame(height: 44).contentShape(Rectangle())
      }.buttonStyle(DateControlStyle()).disabled(isToday).padding(.leading, 6)
    }
  }
  private func arrow(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon).font(.system(size: 13, weight: .semibold))
        .frame(width: 44, height: 44).contentShape(Rectangle())
    }.buttonStyle(DateControlStyle()).help(label).accessibilityLabel(label)
  }
  private func move(_ days: Int) {
    selection = min(Date(), calendar.date(byAdding: .day, value: days, to: selection) ?? selection)
  }
}

private struct DateControlStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    DateControlBody(configuration: configuration, enabled: enabled)
  }
  private struct DateControlBody: View {
    let configuration: ButtonStyle.Configuration
    let enabled: Bool
    @State private var hovered = false
    var body: some View {
      configuration.label.foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.45))
        .background(
          enabled && (hovered || configuration.isPressed)
            ? dateAccent.opacity(configuration.isPressed ? 0.16 : 0.08)
            : Paper.surface.opacity(enabled ? 1 : 0.3), in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10).stroke(
            Paper.border.opacity(hovered && enabled ? 0.24 : 0.12))
        )
        .scaleEffect(configuration.isPressed ? 0.96 : 1)
        .onHover { hovered = $0 }
    }
  }
}

private struct DayCalendar: View {
  @Binding var selection: Date
  var onSelect: () -> Void
  @State private var month: Date
  private let calendar = Calendar.current
  init(selection: Binding<Date>, onSelect: @escaping () -> Void) {
    _selection = selection
    self.onSelect = onSelect
    _month = State(
      initialValue: Calendar.current.dateInterval(of: .month, for: selection.wrappedValue)!.start)
  }
  private var offset: Int {
    (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
  }
  private var days: Int { calendar.range(of: .day, in: .month, for: month)!.count }
  private var weekLabels: [String] {
    let names = calendar.veryShortStandaloneWeekdaySymbols
    return (0..<7).map { names[($0 + calendar.firstWeekday - 1) % 7] }
  }
  var body: some View {
    VStack(spacing: 16) {
      HStack {
        Text(month.formatted(.dateTime.month(.wide).year())).font(
          .system(size: 16, weight: .semibold))
        Spacer()
        monthButton(-1, icon: "chevron.left")
        monthButton(1, icon: "chevron.right")
          .disabled(calendar.isDate(month, equalTo: Date(), toGranularity: .month))
      }
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 4), count: 7), spacing: 6) {
        ForEach(0..<7, id: \.self) { i in
          Text(weekLabels[i]).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .frame(width: 40, height: 22)
        }
        ForEach(0..<((offset + days + 6) / 7 * 7), id: \.self) { index in
          let day = index - offset + 1
          if day > 0 && day <= days {
            let date = calendar.date(byAdding: .day, value: day - 1, to: month)!
            let selected = calendar.isDate(date, inSameDayAs: selection)
            Button {
              selection = date
              onSelect()
            } label: {
              VStack(spacing: 3) {
                Text("\(day)").font(.system(size: 13, weight: selected ? .semibold : .medium))
                  .monospacedDigit()
                Circle().fill(
                  calendar.isDateInToday(date)
                    ? (selected ? Paper.selectionInk : dateAccent) : .clear
                ).frame(width: 3, height: 3)
              }.frame(width: 40, height: 40)
                .background(selected ? dateAccent : .clear, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(selected ? Paper.selectionInk : Paper.ink)
            }.buttonStyle(.plain).contentShape(Rectangle())
              .disabled(date > calendar.startOfDay(for: Date()))
              .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
              .accessibilityAddTraits(selected ? .isSelected : [])
          } else {
            Color.clear.frame(width: 40, height: 40)
          }
        }
      }
      Divider()
      HStack {
        Text("Choose a day to explore").font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer()
        Button("Today") {
          selection = Date()
          onSelect()
        }.font(.system(size: 12, weight: .semibold)).buttonStyle(.bordered).controlSize(.large)
      }
    }.padding(20).frame(width: 344).background(Paper.surface).foregroundStyle(Paper.ink)
  }
  private func monthButton(_ amount: Int, icon: String) -> some View {
    Button {
      month = calendar.date(byAdding: .month, value: amount, to: month)!
    } label: {
      Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(
        width: 40, height: 40)
    }.buttonStyle(DateControlStyle()).accessibilityLabel(
      amount < 0 ? "Previous month" : "Next month")
  }
}
