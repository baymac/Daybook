import AppKit
import Charts
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
  case today, week, apps, settings
  var id: String { rawValue }
  var title: String {
    switch self {
    case .today: return "Dashboard"
    case .week: return "Week in review"
    case .apps: return "Apps & sites"
    case .settings: return "Settings"
    }
  }
  var icon: String {
    switch self {
    case .today: return "sun.max"
    case .week: return "chart.bar.xaxis"
    case .apps: return "square.grid.2x2"
    case .settings: return "slider.horizontal.3"
    }
  }
}

private enum Paper {
  static let background = Color(red: 0.965, green: 0.956, blue: 0.933)
  static let sidebar = Color(red: 0.935, green: 0.925, blue: 0.900)
  static let ink = Color(red: 0.17, green: 0.21, blue: 0.20)
  static let secondary = Color(red: 0.43, green: 0.46, blue: 0.43)
  static let orange = Color(red: 0.82, green: 0.36, blue: 0.18)
  static let teal = Color(red: 0.22, green: 0.46, blue: 0.42)
}

private func durationText(_ seconds: TimeInterval) -> String {
  if seconds > 0 && seconds < 60 { return "<1m" }
  let minutes = max(0, Int(seconds) / 60)
  return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}

private struct PlotBin: Identifiable {
  let id: Int
  let date: Date
  let seconds: Double
}

struct ContentView: View {
  @EnvironmentObject var model: AppModel
  @State private var search = ""
  @State private var categoryFilter = "all"
  @State private var excludedAppsDraft = ""
  @State private var timelineSelection: Date?

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      VStack(spacing: 0) {
        header
        ScrollView {
          VStack(alignment: .leading, spacing: 26) {
            if let error = model.errorMessage {
              HStack(alignment: .top, spacing: 14) {
                Label(error, systemImage: "exclamationmark.triangle")
                Spacer()
                Button {
                  model.errorMessage = nil
                } label: {
                  Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).help("Dismiss message")
              }.font(.callout).foregroundStyle(Paper.orange).padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Paper.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            switch model.page {
            case .today: today
            case .week: week
            case .apps: apps
            case .settings: settings
            }
          }.padding(32).frame(maxWidth: 1120)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
    }
    .background(Paper.background).foregroundStyle(Paper.ink)
    .tint(Paper.teal).preferredColorScheme(.light)
    .frame(minWidth: 980, minHeight: 680)
    .onAppear { excludedAppsDraft = model.excludedApps }
    .onChange(of: model.day) { _, _ in timelineSelection = nil }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 30) {
      HStack(spacing: 10) {
        Image(systemName: "book.closed.fill").font(.system(size: 23)).foregroundStyle(Paper.orange)
        Text("daybook").font(.system(size: 26, weight: .semibold, design: .serif))
      }.padding(.horizontal, 18).padding(.top, 26)
      VStack(spacing: 5) {
        ForEach(Page.allCases) { page in
          Button {
            model.page = page
          } label: {
            HStack(spacing: 12) {
              Image(systemName: page.icon).font(.system(size: 16)).frame(width: 21)
              Text(page.title).font(
                .system(size: 13, weight: model.page == page ? .semibold : .medium))
              Spacer()
              if model.page == page { Circle().fill(Paper.orange).frame(width: 5, height: 5) }
            }.padding(.horizontal, 14).frame(height: 43)
              .background(
                model.page == page ? Color.white.opacity(0.66) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
              )
              .contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
      }.padding(.horizontal, 12)
      Spacer()
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 7) {
          Circle().fill(model.trackingEnabled && !model.paused ? Paper.teal : Paper.secondary)
            .frame(width: 6, height: 6)
          Text(
            !model.trackingEnabled
              ? "Tracking is off" : model.paused ? "Tracking paused" : "Recording on this Mac"
          )
          .font(.system(size: 11, weight: .medium))
        }
        if model.trackingEnabled {
          Button(model.paused ? "Resume tracking" : "Pause tracking", action: model.togglePause)
            .buttonStyle(.bordered).controlSize(.small)
        }
        Divider()
        Label("Your day stays yours.", systemImage: "lock.shield")
          .font(.system(size: 11)).foregroundStyle(Paper.secondary)
      }.padding(20)
    }.frame(width: 208).background(Paper.sidebar)
  }

  private var header: some View {
    HStack {
      Text(model.page.title).font(.system(size: 15, weight: .semibold))
      Spacer()
      if model.page != .settings {
        HStack(spacing: 6) {
          Button {
            moveDay(-1)
          } label: {
            Image(systemName: "chevron.left").frame(width: 25, height: 30)
          }.help("Previous day")
          DatePicker("Date", selection: $model.day, in: ...Date(), displayedComponents: .date)
            .labelsHidden().datePickerStyle(.field).fixedSize()
          Button {
            moveDay(1)
          } label: {
            Image(systemName: "chevron.right").frame(width: 25, height: 30)
          }
          .disabled(Calendar.current.isDateInToday(model.day)).help("Next day")
          Button("Today") { model.day = Date() }.padding(.leading, 5)
        }.buttonStyle(.plain).font(.system(size: 12))
      }
      Button {
        model.refresh()
      } label: {
        Image(systemName: "arrow.clockwise").frame(width: 32, height: 32)
      }
      .buttonStyle(.plain).help("Refresh")
    }.padding(.horizontal, 32).frame(height: 64)
      .overlay(alignment: .bottom) { Rectangle().fill(Paper.ink.opacity(0.07)).frame(height: 1) }
  }

  private var today: some View {
    VStack(alignment: .leading, spacing: 26) {
      introduction(
        "Understand your screen time.",
        subtitle: model.day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
      if !model.trackingEnabled { startBanner }
      if !model.browserEnabled {
        Button {
          model.page = .settings
        } label: {
          Label("Set up website tracking to classify browser time →", systemImage: "globe")
            .font(.callout).foregroundStyle(Paper.teal)
        }.buttonStyle(.plain)
      }
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
        metric(
          "COMPUTER USAGE", value: durationText(model.total),
          foot: "Foreground and video time; overlaps counted once", symbol: "clock",
          color: Paper.orange)
        metric(
          "APP SWITCHES", value: "\(model.switchCount)", foot: "Changes between foreground apps",
          symbol: "arrow.left.arrow.right", color: Paper.teal)
        metric(
          "FOCUS TIME", value: durationText(model.focusTime),
          foot: "Productive stretches of 25+ minutes", symbol: "scope", color: Paper.teal)
        metric(
          "APPS & SITES", value: "\(model.rows.count)", foot: "Distinct activity entries",
          symbol: "square.grid.2x2", color: Paper.orange)
        metric(
          "FOREGROUND TIME", value: durationText(model.foregroundTotal),
          foot: "The app you were working in", symbol: "macwindow", color: Paper.teal)
        metric(
          "VIDEO PLAYBACK", value: durationText(model.videoTotal),
          foot: "Includes detected background video", symbol: "play.rectangle", color: Paper.orange)
      }
      dayTimeline
      activityChart(weekly: false)
      categoryBreakdown
      panel {
        sectionTitle(
          "Most used apps & sites",
          detail: "Includes video playback · Simultaneous activities may overlap")
        if model.rows.isEmpty {
          empty(
            "No activity recorded",
            "Start tracking or import existing history to see app activity.",
            icon: "square.grid.2x2")
        } else {
          usageList(Array(model.rows.prefix(8)))
        }
        Button("See all activity  →") { model.page = .apps }.buttonStyle(.plain).font(
          .callout.weight(.medium)
        ).foregroundStyle(Paper.teal)
      }
    }
  }

  private var week: some View {
    VStack(alignment: .leading, spacing: 26) {
      introduction(
        "See the shape of your week.",
        subtitle: "Seven days ending \(model.day.formatted(date: .abbreviated, time: .omitted))")
      HStack(spacing: 16) {
        metric(
          "TOTAL ACTIVE TIME", value: durationText(model.total),
          foot: "Across the selected seven days", symbol: "clock", color: Paper.orange)
        metric(
          "DAILY AVERAGE", value: durationText(model.total / 7),
          foot: "Includes days without activity", symbol: "chart.bar", color: Paper.teal)
        metric(
          "APP SWITCHES", value: "\(model.switchCount)", foot: "Across the selected seven days",
          symbol: "arrow.left.arrow.right", color: Paper.orange)
      }
      activityChart(weekly: true)
      categoryBreakdown
      panel {
        sectionTitle("Your week, by app", detail: "Foreground activity across seven days")
        if model.rows.isEmpty {
          empty(
            "No activity for this week", "Start tracking or import existing activity history.",
            icon: "calendar")
        } else {
          usageList(Array(model.rows.prefix(12)))
        }
      }
    }
  }

  private var apps: some View {
    VStack(alignment: .leading, spacing: 24) {
      introduction(
        "The places your day happened.", subtitle: "App and website activity for the selected day")
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(Paper.secondary)
        TextField("Find an app or website", text: $search).textFieldStyle(.plain)
        Spacer()
        Button("Export CSV", action: model.exportCSV).buttonStyle(.bordered)
      }.padding(12).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
      if model.rows.contains(where: { $0.category == .other }) {
        HStack(spacing: 14) {
          Image(systemName: "tag").foregroundStyle(Paper.orange)
          VStack(alignment: .leading, spacing: 5) {
            Text("Review Other activity").font(.callout.weight(.medium))
            Text("These apps and sites need a category. Your choices are remembered across dates.")
              .font(.caption).foregroundStyle(Paper.secondary)
          }
          Spacer()
          Button("Review Other") { categoryFilter = Category.other.rawValue }.buttonStyle(.bordered)
        }.padding(18).background(Paper.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
      }
      HStack {
        Text("Category").font(.callout).foregroundStyle(Paper.secondary)
        Picker("Category filter", selection: $categoryFilter) {
          Text("All categories").tag("all")
          ForEach(Category.allCases, id: \.rawValue) { category in
            Text(category.rawValue.capitalized).tag(category.rawValue)
          }
        }.labelsHidden().frame(width: 170)
        Spacer()
      }
      panel {
        sectionTitle(
          "Activity", detail: "\(durationText(model.total)) total · Categories are editable")
        let filtered = model.rows.filter { row in
          (categoryFilter == "all" || row.category.rawValue == categoryFilter)
            && (search.isEmpty || row.name.localizedCaseInsensitiveContains(search)
              || (row.domain ?? "").localizedCaseInsensitiveContains(search))
        }
        if filtered.isEmpty {
          empty(
            model.rows.isEmpty ? "No activity recorded" : "No matching activity",
            model.rows.isEmpty
              ? "Activity appears after tracking begins."
              : "Choose another category or try a different search.", icon: "square.grid.2x2")
        } else {
          usageList(filtered, editable: true)
        }
      }
      if !model.browserEnabled {
        Label(
          "Website tracking is off. You can enable domain tracking in Settings.",
          systemImage: "lock"
        )
        .font(.callout).foregroundStyle(Paper.secondary)
      }
    }
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 26) {
      introduction(
        "Built around your boundaries.",
        subtitle: "You decide what gets recorded. Everything stays on this Mac.")
      panel {
        Label("Private by design", systemImage: "lock.shield").font(.title3.weight(.medium))
          .foregroundStyle(Paper.teal)
        Text(
          "No usage reports leave this Mac. No advertising, cloud sync, or telemetry. Optional video signals arrive through a local browser bridge; exports are files you control."
        )
        .font(.callout).foregroundStyle(Paper.secondary).lineSpacing(4)
      }
      panel {
        sectionTitle(
          "Activity tracking", detail: "Foreground activity, idle time and browser domains")
        settingRow(
          "Record foreground apps",
          detail:
            "Records the foreground app. App switches count changes between apps during continuous activity."
        ) {
          Button(
            model.trackingEnabled ? "Stop tracking" : "Start tracking", action: model.toggleTracking
          ).buttonStyle(.borderedProminent)
        }
        Divider()
        settingRow(
          "Idle cutoff",
          detail:
            "After this long without input, inactive foreground time is removed. Detected video playback continues to count separately."
        ) {
          Picker(
            "Idle cutoff",
            selection: Binding(get: { model.idleMinutes }, set: { model.setIdleMinutes($0) })
          ) {
            ForEach([1, 2, 3, 5, 10], id: \.self) { minutes in
              Text("\(minutes) \(minutes == 1 ? "minute" : "minutes")").tag(minutes)
            }
          }.labelsHidden().frame(width: 120)
        }
        Divider()
        settingRow(
          "Website domains",
          detail:
            "Optional browser automation access. Saves domains, not full URLs or page content."
        ) {
          Toggle(
            "Website domains",
            isOn: Binding(
              get: { model.browserEnabled },
              set: { enabled in
                if enabled != model.browserEnabled { model.enableBrowserTracking() }
              })
          ).labelsHidden().toggleStyle(.switch)
        }
        Divider()
        settingRow("Open at login", detail: "Keep Daybook available when you sign in.") {
          Toggle(
            "Open at login",
            isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
          ).labelsHidden().toggleStyle(.switch)
        }
      }
      panel {
        sectionTitle("Your data", detail: "Local storage, with a way in and a way out")
        HStack(spacing: 12) {
          Button("Import existing history…", action: model.importTimecard)
          Button("Export activity CSV…", action: model.exportCSV)
          Button("Show data folder", action: model.revealData)
        }.buttonStyle(.bordered).controlSize(.large)
        Text(
          "Importing supports a Timecard SQLite database you select and leaves the original file untouched."
        )
        .font(.caption).foregroundStyle(Paper.secondary)
      }
      panel {
        sectionTitle(
          "Video playback",
          detail:
            "A local browser extension detects real playback, including background tabs and embedded players"
        )
        settingRow(
          "Count video playback",
          detail:
            "Video continues to count while you work elsewhere or stop typing. Pauses, buffering, sleep and missing signals are not extended indefinitely."
        ) {
          Toggle(
            "Count video playback",
            isOn: Binding(get: { model.videoEnabled }, set: model.setVideoEnabled)
          ).labelsHidden().toggleStyle(.switch)
        }
        Text(model.videoStatus).font(.caption).foregroundStyle(Paper.teal)
        HStack {
          Button("Setup guide", action: model.showVideoSetup)
          Button("Show extension folder", action: model.revealVideoExtension)
          Button("Copy pairing code", action: model.copyVideoPairingCode)
        }.buttonStyle(.bordered)
        Text(
          "Computer usage counts overlapping work and video once. App/site and category totals include both activities and can add up to more than computer usage. Domain exclusions also apply to video."
        )
        .font(.caption).foregroundStyle(Paper.secondary)
      }
      panel {
        sectionTitle(
          "Excluded apps & sites",
          detail: "Exclude matching app names or website domains from future tracking")
        TextEditor(text: $excludedAppsDraft)
          .font(.system(size: 12, design: .monospaced))
          .frame(height: 76).padding(6)
          .background(.white, in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(Paper.ink.opacity(0.1)))
        HStack {
          Text("One entry per line, for example Slack or example.com. Existing records are kept.")
            .font(.caption).foregroundStyle(Paper.secondary)
          Spacer()
          Button("Save exclusions") { model.saveExcludedApps(excludedAppsDraft) }.buttonStyle(
            .bordered)
        }
      }
      Text(model.status).font(.caption).foregroundStyle(Paper.secondary).textSelection(.enabled)
      HStack {
        Text("DAYBOOK").tracking(2)
        Text("·")
        Text("A local record of a digital day.")
      }
      .font(.system(size: 10, design: .monospaced)).foregroundStyle(Paper.secondary).padding(
        .top, 8)
    }
  }

  private var startBanner: some View {
    HStack(spacing: 18) {
      Image(systemName: "leaf").font(.system(size: 28, weight: .light)).foregroundStyle(Paper.teal)
      VStack(alignment: .leading, spacing: 5) {
        Text("Start with a clean page.").font(.system(size: 18, design: .serif))
        Text("Enable tracking to record active app time locally on this Mac.").font(.callout)
          .foregroundStyle(Paper.secondary)
      }
      Spacer()
      Button("Start tracking", action: model.toggleTracking).buttonStyle(.borderedProminent)
        .controlSize(.large)
    }.padding(22).background(Paper.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
  }

  private func introduction(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 31, weight: .regular, design: .serif))
      Text(subtitle).font(.system(size: 13)).foregroundStyle(Paper.secondary)
    }
  }

  private func metric(_ title: String, value: String, foot: String, symbol: String, color: Color)
    -> some View
  {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(
          Paper.secondary)
        Spacer()
        Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(color)
      }
      Text(value).font(.system(size: 34, weight: .regular, design: .monospaced)).monospacedDigit()
        .minimumScaleFactor(0.65).lineLimit(1)
      Text(foot).font(.system(size: 11)).foregroundStyle(Paper.secondary)
    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
      .background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 16))
  }

  private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 18, content: content).padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 18))
  }

  private func sectionTitle(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 17, weight: .medium, design: .serif))
      Text(detail).font(.system(size: 11)).foregroundStyle(Paper.secondary)
    }
  }

  private func empty(_ title: String, _ detail: String, icon: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: icon).font(.system(size: 30, weight: .ultraLight)).foregroundStyle(
        Paper.teal)
      Text(title).font(.system(size: 18, design: .serif))
      Text(detail).font(.callout).foregroundStyle(Paper.secondary).multilineTextAlignment(.center)
        .frame(maxWidth: 380)
    }.frame(maxWidth: .infinity).padding(.vertical, 36)
  }

  private func usageList(_ rows: [UsageItem], editable: Bool = false) -> some View {
    VStack(spacing: 0) {
      ForEach(rows) { row in
        HStack(spacing: 13) {
          AppBadge(bundleID: row.bundleID, domain: row.domain)
          VStack(alignment: .leading, spacing: 5) {
            Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(
              "\(row.visits) \(row.visits == 1 ? "visit" : "visits") · \(Int((row.duration / max(model.activityTime, 1) * 100).rounded()))% of activity time"
            )
            .font(.system(size: 10)).foregroundStyle(Paper.secondary)
            GeometryReader { geo in
              Capsule().fill(Paper.teal.opacity(0.12))
                .overlay(alignment: .leading) {
                  Capsule().fill(Paper.teal.opacity(0.6)).frame(
                    width: max(
                      0, geo.size.width * min(1, row.duration / max(model.activityTime, 1))))
                }
            }.frame(height: 3).frame(maxWidth: 240)
          }
          Spacer(minLength: 12)
          if editable {
            Menu {
              ForEach(Category.allCases, id: \.rawValue) { category in
                Button(category.rawValue.capitalized) { model.setCategory(category, for: row.id) }
              }
            } label: {
              Text(row.category.rawValue.capitalized).font(.caption).frame(width: 90)
            }.menuStyle(.borderlessButton).fixedSize()
          }
          Text(durationText(row.duration)).font(.system(size: 13, design: .monospaced))
            .monospacedDigit().frame(width: 82, alignment: .trailing)
        }.padding(.vertical, 12)
        if row.id != rows.last?.id { Divider().opacity(0.45) }
      }
    }
  }

  private func activityChart(weekly: Bool) -> some View {
    let bins = plotBins(weekly: weekly)
    return panel {
      HStack {
        sectionTitle(
          weekly ? "Daily active time" : "Hourly active time",
          detail: weekly ? "Active time each day" : "Active minutes each hour")
        Spacer()
        Label("Active time", systemImage: "circle.fill").font(.system(size: 10)).foregroundStyle(
          Paper.teal)
      }
      if bins.allSatisfy({ $0.seconds == 0 }) {
        empty(
          "No recorded activity",
          "This chart shows active time after you start tracking or import history.",
          icon: "chart.bar.xaxis")
      } else {
        Chart(bins) { bin in
          BarMark(
            x: .value(weekly ? "Day" : "Hour", bin.date, unit: weekly ? .day : .hour),
            y: .value("Minutes", bin.seconds / 60)
          )
          .foregroundStyle(Paper.teal.gradient).cornerRadius(3)
        }
        .chartXAxis {
          AxisMarks(values: .stride(by: weekly ? .day : .hour, count: weekly ? 1 : 4)) { _ in
            AxisGridLine().foregroundStyle(Paper.ink.opacity(0.04))
            AxisValueLabel(
              format: weekly
                ? .dateTime.weekday(.abbreviated)
                : .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading) { _ in
            AxisGridLine().foregroundStyle(Paper.ink.opacity(0.06))
            AxisValueLabel()
          }
        }
        .chartYScale(domain: 0...max(60, (bins.map(\.seconds).max() ?? 0) / 60))
        .frame(height: 185).padding(.top, 10)
      }
    }
  }

  private var categoryBreakdown: some View {
    panel {
      sectionTitle(
        "Time by category",
        detail: "Share of activity time · Parallel video can overlap foreground work")
      if model.rows.isEmpty {
        empty(
          "No categories to compare",
          "Your recorded apps and websites are grouped here automatically.", icon: "chart.pie")
      } else {
        ForEach(usedCategories, id: \.rawValue) { category in
          let seconds = model.rows.filter { $0.category == category }.reduce(0) { $0 + $1.duration }
          let share = seconds / max(model.activityTime, 1)
          HStack(spacing: 14) {
            Circle().fill(categoryColor(category)).frame(width: 8, height: 8)
            Text(category.rawValue.capitalized).font(.callout).frame(
              width: 110, alignment: .leading)
            GeometryReader { geo in
              Capsule().fill(categoryColor(category).opacity(0.1))
                .overlay(alignment: .leading) {
                  Capsule().fill(categoryColor(category)).frame(
                    width: geo.size.width * min(1, max(0, share)))
                }
            }.frame(height: 7)
            Text("\(Int((share * 100).rounded()))%")
              .font(.system(size: 12, design: .monospaced)).monospacedDigit().frame(
                width: 44, alignment: .trailing
              )
              .foregroundStyle(Paper.secondary)
            Text(durationText(seconds)).font(.system(size: 12, design: .monospaced))
              .monospacedDigit().frame(width: 80, alignment: .trailing)
          }.padding(.vertical, 3)
        }
      }
    }
  }

  private var dayTimeline: some View {
    let start = Calendar.current.startOfDay(for: model.day)
    let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
    let sessions = model.timelineSessions.filter { $0.end > start && $0.start < end }
    return panel {
      sectionTitle(
        "Your day, in sequence",
        detail:
          "Foreground sessions and detected video · Overlapping activities can appear together")
      if sessions.isEmpty {
        empty(
          "No sessions for this date", "Start tracking to build a chronological view of your day.",
          icon: "timeline.selection")
      } else {
        Chart {
          ForEach(sessions) { session in
            let category = sessionCategory(session)
            RectangleMark(
              xStart: .value("Start", max(session.start, start)),
              xEnd: .value("End", min(session.end, end)),
              y: .value("Category", category.rawValue.capitalized),
              height: .ratio(0.62)
            ).foregroundStyle(categoryColor(category)).cornerRadius(2)
          }
          if let selected = timelineSelection {
            RuleMark(x: .value("Selected time", selected))
              .foregroundStyle(Paper.ink.opacity(0.4)).lineStyle(
                StrokeStyle(lineWidth: 1, dash: [3, 3]))
          }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: usedCategories.map { $0.rawValue.capitalized })
        .chartXAxis {
          AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
            AxisGridLine().foregroundStyle(Paper.ink.opacity(0.07))
            AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
          }
        }
        .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 10)) } }
        .chartXSelection(value: $timelineSelection)
        .frame(height: 215).padding(.top, 8)
        if let selected = timelineSelection {
          let active = sessions.filter { $0.start <= selected && $0.end > selected }
          if !active.isEmpty {
            ForEach(active) { session in
              HStack(spacing: 10) {
                Circle().fill(categoryColor(sessionCategory(session))).frame(width: 7, height: 7)
                Text(
                  (session.bundleID == "daybook.video" ? "Video · " : "")
                    + (session.domain ?? session.appName)
                ).fontWeight(.medium)
                Text(
                  "\(max(start, session.start).formatted(date: .omitted, time: .shortened)) – \(min(end, session.end).formatted(date: .omitted, time: .shortened))"
                )
                Spacer()
                Text(
                  durationText(min(end, session.end).timeIntervalSince(max(start, session.start)))
                )
                .font(.system(.caption, design: .monospaced))
              }.font(.caption)
            }
          } else {
            Text("\(selected.formatted(date: .omitted, time: .shortened)) · No recorded activity")
              .font(.caption).foregroundStyle(Paper.secondary)
          }
        } else {
          Text("Select or drag across the chart to see the app, time range, and session duration.")
            .font(.caption).foregroundStyle(Paper.secondary)
        }
      }
    }
  }

  private func sessionCategory(_ session: ActivitySession) -> Category {
    model.categoryForSession(session)
  }

  private var usedCategories: [Category] {
    Category.allCases.filter { category in
      model.rows.contains { $0.category == category && $0.duration > 0 }
    }
  }

  private func categoryColor(_ category: Category) -> Color {
    switch category {
    case .productivity: return Paper.teal
    case .communication: return Color(red: 0.25, green: 0.48, blue: 0.65)
    case .social: return Color(red: 0.63, green: 0.40, blue: 0.60)
    case .entertainment: return Paper.orange
    case .learning: return Color(red: 0.55, green: 0.57, blue: 0.28)
    case .utilities: return Color(red: 0.56, green: 0.48, blue: 0.37)
    case .finance: return Color(red: 0.24, green: 0.43, blue: 0.37)
    case .shopping: return Color(red: 0.72, green: 0.48, blue: 0.25)
    case .news: return Color(red: 0.40, green: 0.44, blue: 0.62)
    case .other: return Color(red: 0.57, green: 0.59, blue: 0.56)
    }
  }

  private func settingRow<Content: View>(
    _ title: String, detail: String, @ViewBuilder control: () -> Content
  ) -> some View {
    HStack(spacing: 28) {
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.callout.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(Paper.secondary).fixedSize(
          horizontal: false, vertical: true)
      }
      Spacer()
      control()
    }.padding(.vertical, 5)
  }

  private func moveDay(_ amount: Int) {
    if let next = Calendar.current.date(byAdding: .day, value: amount, to: model.day) {
      model.day = min(next, Date())
    }
  }

  private func plotBins(weekly: Bool) -> [PlotBin] {
    let calendar = Calendar.current
    let selected = calendar.startOfDay(for: model.day)
    let start = weekly ? calendar.date(byAdding: .day, value: -6, to: selected)! : selected
    let endOfDay = calendar.date(byAdding: .day, value: 1, to: selected)!
    let count = weekly ? 7 : Int(endOfDay.timeIntervalSince(selected) / 3600)
    return (0..<count).map { index in
      let date = calendar.date(byAdding: weekly ? .day : .hour, value: index, to: start)!
      let end = calendar.date(byAdding: weekly ? .day : .hour, value: 1, to: date)!
      let intervals = model.timelineSessions.compactMap { session -> DateInterval? in
        let a = max(session.start, date)
        let b = min(session.end, end)
        return b > a ? DateInterval(start: a, end: b) : nil
      }
      let seconds = PlaybackMath.duration(intervals)
      return PlotBin(id: index, date: date, seconds: seconds)
    }
  }
}

private struct AppBadge: View {
  let bundleID: String
  let domain: String?
  var body: some View {
    Group {
      if domain != nil {
        Image(systemName: "globe").font(.system(size: 19)).foregroundStyle(Paper.teal)
      } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
          .padding(4)
      } else {
        Image(systemName: "app").font(.system(size: 19)).foregroundStyle(Paper.secondary)
      }
    }.frame(width: 36, height: 36).background(
      Paper.background, in: RoundedRectangle(cornerRadius: 9))
  }
}
