import Foundation
import Cocoa
import UniformTypeIdentifiers
import PangolinGitCore

/// Repository statistics mirroring TortoiseGit's `CStatGraphDlg` (`src/TortoiseProc/StatGraphDlg.cpp`):
/// a summary page, commits by date / by author, percentage of authorship and changed lines by
/// date, drawn as pie, line, stacked line, bar or stacked bar charts, over the revisions the Log
/// shows. Line counts are calculated on request (`git log --numstat`), as TortoiseGit does.
public final class StatisticsWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource {

    public let repositoryPath: PangolinPath

    enum Page: Int, CaseIterable {
        case summary, commitsByDate, commitsByAuthor, authorship, linesWith, linesWithout

        var title: String {
            switch self {
            case .summary: return "Statistics"
            case .commitsByDate: return "Commits by Date"
            case .commitsByAuthor: return "Commits by Author"
            case .authorship: return "Percentage of Authorship"
            case .linesWith: return "Changed Lines by Date (incl. new/deleted files)"
            case .linesWithout: return "Changed Lines by Date (changes only)"
            }
        }

        var isByDate: Bool { [.commitsByDate, .linesWith, .linesWithout].contains(self) }
        var needsLineStats: Bool { self == .linesWith || self == .linesWithout }
    }

    private var revisions: [GitRevision]
    /// Walk arguments of the Log's query, so line statistics cover the same commits.
    private let walkArguments: [String]
    private var fileStats: [String: CommitFileStats]?
    private var statistics: LogStatistics?
    private var tableRows: [(name: String, value: String, share: String)] = []
    private let config = ConfigManager.shared

    let pagePopup = NSPopUpButton()
    private let styleControl = NSSegmentedControl()
    private let calculateButton = NSButton(title: "Calculate Lines", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save Graph…", target: nil, action: nil)
    private let caseCheck = NSButton(checkboxWithTitle: "Authors case-sensitive", target: nil, action: nil)
    private let committerCheck = NSButton(checkboxWithTitle: "Use committer names", target: nil, action: nil)
    private let commitDatesCheck = NSButton(checkboxWithTitle: "Use commit dates", target: nil, action: nil)
    private let sortCheck = NSButton(checkboxWithTitle: "Sort by commit count", target: nil, action: nil)
    private let authorsSlider = NSSlider()
    private let authorsLabel = NSTextField(labelWithString: "")
    private let chartView = StatsChartView()
    private let summaryView = NSTextView()
    private let summaryScroll = NSScrollView()
    private let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "Calculating statistics…")
    private let spinner = NSProgressIndicator()

    /// - Parameters:
    ///   - revisions: the commits to analyse (the Log's current list); nil loads the history of HEAD.
    ///   - walkArguments: `git log` walk arguments matching `revisions`, for line statistics.
    public init(repositoryPath: PangolinPath, revisions: [GitRevision]? = nil, walkArguments: [String]? = nil) {
        self.repositoryPath = repositoryPath
        self.revisions = revisions ?? []
        var defaultQuery = GitLogQuery()
        defaultQuery.useMailmap = ConfigManager.shared.useMailmap
        self.walkArguments = walkArguments ?? defaultQuery.walkArguments()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Statistics — \(repositoryPath.url.lastPathComponent)"
        window.minSize = NSSize(width: 760, height: 500)
        super.init(window: window)
        setupUI()
        if revisions == nil {
            loadRevisions(query: defaultQuery)
        } else {
            recalculate()
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        pagePopup.addItems(withTitles: Page.allCases.map(\.title))
        pagePopup.target = self
        pagePopup.action = #selector(refreshView)

        styleControl.segmentCount = StatsChartView.Style.allCases.count
        for style in StatsChartView.Style.allCases {
            styleControl.setLabel(style.title, forSegment: style.rawValue)
        }
        styleControl.trackingMode = .selectOne
        styleControl.selectedSegment = StatsChartView.Style.bar.rawValue
        styleControl.target = self
        styleControl.action = #selector(refreshView)

        calculateButton.target = self
        calculateButton.action = #selector(calculateLines)
        calculateButton.toolTip = "Count added and removed lines of every commit (git log --numstat)"
        saveButton.target = self
        saveButton.action = #selector(saveGraph)

        let row1 = NSStackView(views: [pagePopup, styleControl, NSView(), calculateButton, saveButton])
        row1.spacing = 8

        caseCheck.state = config.statsAuthorsCaseSensitive ? .on : .off
        committerCheck.state = config.statsUseCommitterNames ? .on : .off
        commitDatesCheck.state = config.statsUseCommitDates ? .on : .off
        sortCheck.state = config.statsSortByCommitCount ? .on : .off
        for check in [caseCheck, committerCheck, commitDatesCheck, sortCheck] {
            check.target = self
            check.action = #selector(optionsChanged)
        }
        authorsSlider.minValue = 1
        authorsSlider.maxValue = 30
        authorsSlider.integerValue = config.statsAuthorsShown
        authorsSlider.target = self
        authorsSlider.action = #selector(sliderChanged)
        authorsSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let row2 = NSStackView(views: [caseCheck, committerCheck, commitDatesCheck, sortCheck, NSView(), authorsLabel, authorsSlider])
        row2.spacing = 12

        summaryView.isEditable = false
        summaryView.textContainerInset = NSSize(width: 10, height: 10)
        summaryView.isVerticallyResizable = true
        summaryView.autoresizingMask = [.width]
        summaryScroll.documentView = summaryView
        summaryScroll.hasVerticalScroller = true
        summaryScroll.borderType = .bezelBorder

        for (id, title, width) in [("Name", "Name", 420.0), ("Value", "Value", 140.0), ("Share", "Share", 120.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.delegate = self
        tableView.dataSource = self
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.keyEquivalent = "\u{1b}"
        let bottom = NSStackView(views: [spinner, statusLabel, NSView(), closeButton])

        for view in [row1, row2, chartView, summaryScroll, tableScroll, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16).isActive = true
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16).isActive = true
        }
        NSLayoutConstraint.activate([
            row1.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row2.topAnchor.constraint(equalTo: row1.bottomAnchor, constant: 8),
            chartView.topAnchor.constraint(equalTo: row2.bottomAnchor, constant: 10),
            chartView.heightAnchor.constraint(equalTo: contentView.heightAnchor, multiplier: 0.55),
            tableScroll.topAnchor.constraint(equalTo: chartView.bottomAnchor, constant: 8),
            tableScroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            summaryScroll.topAnchor.constraint(equalTo: row2.bottomAnchor, constant: 10),
            summaryScroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            bottom.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    // MARK: - Data

    private func loadRevisions(query: GitLogQuery) {
        spinner.startAnimation(nil)
        let root = repositoryPath
        Task { @MainActor in
            do {
                let repo = try GitRepository(rootPath: root)
                self.revisions = try await repo.log(query: query).map(\.revision)
                self.recalculate()
            } catch {
                self.statusLabel.stringValue = "Statistics error: \(error.localizedDescription)"
            }
            self.spinner.stopAnimation(nil)
        }
    }

    private var options: LogStatistics.Options {
        var options = LogStatistics.Options()
        options.authorsCaseSensitive = caseCheck.state == .on
        options.useCommitterNames = committerCheck.state == .on
        options.useCommitDates = commitDatesCheck.state == .on
        return options
    }

    private func recalculate() {
        let stats = LogStatistics(entries: revisions, fileStats: fileStats, options: options)
        statistics = stats
        authorsSlider.maxValue = Double(max(stats.authors.count, 1))
        statusLabel.stringValue = "\(stats.totalCommits) commits by \(stats.authors.count) authors"
            + (fileStats == nil ? "" : "; line statistics calculated")
        refreshView()
    }

    @objc private func calculateLines() {
        spinner.startAnimation(nil)
        calculateButton.isEnabled = false
        statusLabel.stringValue = "Counting changed lines…"
        let args = CommitStatsParser.arguments + walkArguments
        let root = repositoryPath
        Task { @MainActor in
            do {
                let output = try await GitCLIRunner().runChecked(arguments: args, workingDirectory: root)
                self.fileStats = CommitStatsParser.parse(output)
                self.recalculate()
            } catch {
                self.statusLabel.stringValue = "Could not count lines: \(error.localizedDescription)"
                self.calculateButton.isEnabled = true
            }
            self.spinner.stopAnimation(nil)
        }
    }

    @objc private func optionsChanged() {
        config.statsAuthorsCaseSensitive = caseCheck.state == .on
        config.statsUseCommitterNames = committerCheck.state == .on
        config.statsUseCommitDates = commitDatesCheck.state == .on
        config.statsSortByCommitCount = sortCheck.state == .on
        recalculate()
    }

    @objc private func sliderChanged() {
        config.statsAuthorsShown = authorsSlider.integerValue
        refreshView()
    }

    // MARK: - Pages

    private var page: Page { Page(rawValue: pagePopup.indexOfSelectedItem) ?? .summary }

    @objc private func refreshView() {
        guard let stats = statistics else { return }
        let page = self.page
        let isSummary = page == .summary
        summaryScroll.isHidden = !isSummary
        chartView.isHidden = isSummary
        tableScroll.isHidden = isSummary
        saveButton.isEnabled = !isSummary
        calculateButton.isEnabled = fileStats == nil
        styleControl.isEnabled = !isSummary
        authorsLabel.stringValue = "Authors shown individually: \(min(authorsSlider.integerValue, stats.authors.count))"

        // Pie only for author pages; lines only for date pages (as in TortoiseGit).
        for style in StatsChartView.Style.allCases {
            let enabled: Bool
            switch style {
            case .pie: enabled = !page.isByDate
            case .line, .stackedLine: enabled = page.isByDate
            case .bar, .stackedBar: enabled = true
            }
            styleControl.setEnabled(enabled, forSegment: style.rawValue)
        }
        if let style = StatsChartView.Style(rawValue: styleControl.selectedSegment), !styleControl.isEnabled(forSegment: style.rawValue) {
            styleControl.selectedSegment = page.isByDate ? StatsChartView.Style.stackedBar.rawValue : StatsChartView.Style.bar.rawValue
        }
        chartView.style = StatsChartView.Style(rawValue: styleControl.selectedSegment) ?? .bar

        let split = stats.individualAuthors(limit: authorsSlider.integerValue, sortByCommitCount: sortCheck.state == .on)
        let others = "Others (\(split.others.count))"

        switch page {
        case .summary:
            summaryView.textStorage?.setAttributedString(summaryText(stats))
            tableRows = []
        case .commitsByAuthor, .authorship:
            let values: [String: Double] = page == .commitsByAuthor
                ? stats.commitsPerAuthor.mapValues(Double.init)
                : stats.percentageOfAuthorship
            var categories = split.shown
            var numbers = split.shown.map { values[$0] ?? 0 }
            if !split.others.isEmpty {
                categories.append(others)
                numbers.append(split.others.reduce(0) { $0 + (values[$1] ?? 0) })
            }
            chartView.title = page.title
            chartView.valueLabel = page == .commitsByAuthor ? "Commits" : "%"
            chartView.categories = categories
            chartView.series = [StatsChartView.Series(name: page == .commitsByAuthor ? "Commits" : "Authorship", values: numbers)]
            let total = numbers.reduce(0, +)
            tableRows = zip(categories, numbers).map { name, value in
                (name, page == .commitsByAuthor ? "\(Int(value))" : String(format: "%.2f %%", value),
                 total > 0 ? String(format: "%.1f %%", value / total * 100) : "")
            }
        case .commitsByDate, .linesWith, .linesWithout:
            if page.needsLineStats && fileStats == nil {
                chartView.title = "Press “Calculate Lines” to count changed lines"
                chartView.categories = []
                chartView.series = []
                tableRows = []
                break
            }
            func value(_ bucket: LogStatistics.Bucket, _ author: String) -> Int {
                switch page {
                case .linesWith: return bucket.linesWithByAuthor[author] ?? 0
                case .linesWithout: return bucket.linesWithoutByAuthor[author] ?? 0
                default: return bucket.commitsByAuthor[author] ?? 0
                }
            }
            var series = split.shown.map { author in
                StatsChartView.Series(name: author, values: stats.buckets.map { Double(value($0, author)) })
            }
            if !split.others.isEmpty {
                series.append(StatsChartView.Series(name: others, values: stats.buckets.map { bucket in
                    Double(split.others.reduce(0) { $0 + value(bucket, $1) })
                }))
            }
            chartView.title = "\(page.title) — per \(stats.unit.title)"
            chartView.valueLabel = page == .commitsByDate ? "Commits" : "Lines"
            chartView.categories = stats.buckets.map(\.label)
            chartView.series = series
            let totals = stats.buckets.map { bucket in Double(stats.authors.reduce(0) { $0 + value(bucket, $1) }) }
            let sum = totals.reduce(0, +)
            tableRows = zip(stats.buckets, totals).reversed().map { bucket, total in
                (bucket.label, "\(Int(total))", sum > 0 ? String(format: "%.1f %%", total / sum * 100) : "")
            }
        }
        tableView.reloadData()
    }

    private func summaryText(_ stats: LogStatistics) -> NSAttributedString {
        let unit = stats.unit.title
        var lines: [(String, String)] = []
        lines.append(("Number of \(unit)s with commits", "\(stats.buckets.count)"))
        lines.append(("Number of authors", "\(stats.authors.count)"))
        lines.append(("Total commits", "\(stats.totalCommits)"))
        if stats.hasLineStats {
            lines.append(("Total file changes", "\(stats.totalFileChanges)"))
            lines.append(("Lines added / removed", "\(stats.linesAdded) / \(stats.linesRemoved)"))
            lines.append(("Lines in new / deleted files", "\(stats.linesInNewFiles) / \(stats.linesInDeletedFiles)"))
        } else {
            lines.append(("Total file changes", "press “Calculate Lines”"))
        }
        if let first = stats.firstDate, let last = stats.lastDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            lines.append(("Period", "\(formatter.string(from: first)) – \(formatter.string(from: last))"))
        }
        let perUnit = stats.commitsPerUnit
        lines.append(("Commits per \(unit) (avg / max / min)", String(format: "%.1f / %d / %d", perUnit.average, perUnit.maximum, perUnit.minimum)))
        if let active = stats.mostAndLeastActive {
            lines.append(("Most active author", "\(active.most.name)  (\(String(format: "%.1f", active.most.average)) / \(active.most.maximum) / \(active.most.minimum) per \(unit))"))
            lines.append(("Least active author", "\(active.least.name)  (\(String(format: "%.1f", active.least.average)) / \(active.least.maximum) / \(active.least.minimum) per \(unit))"))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 280)]
        paragraph.paragraphSpacing = 6
        let result = NSMutableAttributedString()
        for (label, value) in lines {
            result.append(NSAttributedString(string: label + "\t", attributes: [.font: NSFont.boldSystemFont(ofSize: 13),
                                                                               .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]))
            result.append(NSAttributedString(string: value + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                               .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
        }
        return result
    }

    /// Writes the chart as PNG (TortoiseGit's "Save graph as…").
    @objc private func saveGraph() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(repositoryPath.filename)-\(page.title.replacingOccurrences(of: " ", with: "-")).png"
        guard panel.runModal() == .OK, let url = panel.url,
              let rep = chartView.bitmapImageRepForCachingDisplay(in: chartView.bounds) else { return }
        chartView.cacheDisplay(in: chartView.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func closeClicked() {
        window?.close()
    }

    // MARK: - Table

    public func numberOfRows(in tableView: NSTableView) -> Int {
        tableRows.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = LogTextCellView.make(in: tableView, identifier: "StatCell", owner: self)
        let item = tableRows[row]
        switch tableColumn?.identifier.rawValue {
        case "Name": cell.configure(item.name, font: .systemFont(ofSize: 12))
        case "Value": cell.configure(item.value, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
        default: cell.configure(item.share, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .secondaryLabelColor)
        }
        return cell
    }
}

/// Chart canvas for the statistics pages (TortoiseGit's `MyGraph`): pie, line, stacked line,
/// bar and stacked bar, with value axis, category labels and a legend.
final class StatsChartView: NSView {
    enum Style: Int, CaseIterable {
        case pie, stackedLine, line, stackedBar, bar

        var title: String {
            switch self {
            case .pie: return "Pie"
            case .stackedLine: return "Stacked Line"
            case .line: return "Line"
            case .stackedBar: return "Stacked Bar"
            case .bar: return "Bar"
            }
        }
    }

    struct Series {
        let name: String
        let values: [Double]
    }

    var style: Style = .bar { didSet { needsDisplay = true } }
    var title = "" { didSet { needsDisplay = true } }
    var valueLabel = "" { didSet { needsDisplay = true } }
    var categories: [String] = [] { didSet { needsDisplay = true } }
    var series: [Series] = [] { didSet { needsDisplay = true } }

    private static let palette: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemRed,
        .systemTeal, .systemYellow, .systemPink, .systemIndigo, .systemBrown, .systemMint, .systemCyan
    ]

    static func color(_ index: Int, name: String) -> NSColor {
        name.hasPrefix("Others") ? .systemGray : palette[index % palette.count]
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let titleString = NSAttributedString(string: title, attributes: titleAttributes)
        titleString.draw(at: NSPoint(x: (bounds.width - titleString.size().width) / 2, y: bounds.height - 22))
        guard !categories.isEmpty, !series.isEmpty else { return }

        if style == .pie {
            drawPie()
        } else {
            drawAxesChart()
        }
    }

    private var smallAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
    }

    /// Legend entries down the right edge; returns the width used.
    private func drawLegend(_ names: [String], values: [String]? = nil) -> CGFloat {
        let width: CGFloat = min(220, bounds.width * 0.3)
        var y = bounds.height - 44
        for (index, name) in names.enumerated() {
            guard y > 10 else { break }
            Self.color(index, name: name).setFill()
            NSRect(x: bounds.width - width, y: y + 2, width: 10, height: 10).fill()
            let text = values.map { "\(name) — \($0[index])" } ?? name
            NSAttributedString(string: text, attributes: smallAttributes)
                .draw(with: NSRect(x: bounds.width - width + 14, y: y, width: width - 16, height: 14), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            y -= 16
        }
        return width
    }

    private func drawPie() {
        let values = series[0].values
        let total = values.reduce(0, +)
        guard total > 0 else { return }
        let legendWidth = drawLegend(categories, values: values.map { String(format: "%.1f%%", $0 / total * 100) })
        let area = NSRect(x: 10, y: 10, width: bounds.width - legendWidth - 30, height: bounds.height - 44)
        let radius = min(area.width, area.height) / 2
        let center = NSPoint(x: area.midX, y: area.midY)
        var angle: CGFloat = 90
        for (index, value) in values.enumerated() where value > 0 {
            let sweep = CGFloat(value / total) * 360
            let path = NSBezierPath()
            path.move(to: center)
            path.appendArc(withCenter: center, radius: radius, startAngle: angle, endAngle: angle - sweep, clockwise: true)
            path.close()
            Self.color(index, name: categories[index]).withAlphaComponent(0.85).setFill()
            path.fill()
            NSColor.textBackgroundColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            angle -= sweep
        }
    }

    private func drawAxesChart() {
        let stacked = style == .stackedBar || style == .stackedLine
        let legendWidth = series.count > 1 ? drawLegend(series.map(\.name)) : 0
        let plot = NSRect(x: 54, y: 46, width: bounds.width - 54 - legendWidth - 24, height: bounds.height - 46 - 34)
        guard plot.width > 20, plot.height > 20 else { return }
        let count = categories.count
        var maxValue = 0.0
        for index in 0..<count {
            let values = series.map { $0.values.indices.contains(index) ? $0.values[index] : 0 }
            maxValue = max(maxValue, stacked ? values.reduce(0, +) : (values.max() ?? 0))
        }
        maxValue = Self.niceCeiling(max(maxValue, 1))

        // Value axis with five grid lines.
        NSColor.separatorColor.setStroke()
        for step in 0...5 {
            let y = plot.minY + plot.height * CGFloat(step) / 5
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
            grid.lineWidth = step == 0 ? 1 : 0.5
            grid.stroke()
            let label = NSAttributedString(string: Self.format(maxValue * Double(step) / 5), attributes: smallAttributes)
            label.draw(at: NSPoint(x: plot.minX - label.size().width - 6, y: y - 6))
        }
        NSAttributedString(string: valueLabel, attributes: smallAttributes).draw(at: NSPoint(x: 6, y: plot.maxY + 6))

        let slot = plot.width / CGFloat(count)
        func y(_ value: Double) -> CGFloat { plot.minY + CGFloat(value / maxValue) * plot.height }

        // Category labels, thinned out so they do not overlap.
        let labelEvery = max(1, Int(ceil(70 / slot)))
        for (index, category) in categories.enumerated() where index % labelEvery == 0 {
            let label = NSAttributedString(string: category, attributes: smallAttributes)
            let width = min(label.size().width, slot * CGFloat(labelEvery) - 4)
            label.draw(with: NSRect(x: plot.minX + slot * (CGFloat(index) + 0.5) - width / 2, y: plot.minY - 18, width: width, height: 14),
                       options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        }

        switch style {
        case .bar, .stackedBar:
            let groupWidth = slot * 0.8
            for index in 0..<count {
                var base = 0.0
                for (seriesIndex, item) in series.enumerated() {
                    let value = item.values.indices.contains(index) ? item.values[index] : 0
                    guard value > 0 else { continue }
                    Self.color(seriesIndex, name: item.name).withAlphaComponent(0.85).setFill()
                    let left = plot.minX + slot * CGFloat(index) + slot * 0.1
                    if stacked {
                        NSRect(x: left, y: y(base), width: groupWidth, height: y(base + value) - y(base)).fill()
                        base += value
                    } else {
                        let width = groupWidth / CGFloat(series.count)
                        NSRect(x: left + width * CGFloat(seriesIndex), y: plot.minY, width: max(width - 1, 1), height: y(value) - plot.minY).fill()
                    }
                }
            }
        case .line, .stackedLine:
            var running = [Double](repeating: 0, count: count)
            for (seriesIndex, item) in series.enumerated() {
                let path = NSBezierPath()
                for index in 0..<count {
                    let value = (item.values.indices.contains(index) ? item.values[index] : 0) + (stacked ? running[index] : 0)
                    running[index] = value
                    let point = NSPoint(x: plot.minX + slot * (CGFloat(index) + 0.5), y: y(value))
                    if index == 0 { path.move(to: point) } else { path.line(to: point) }
                }
                Self.color(seriesIndex, name: item.name).setStroke()
                path.lineWidth = 2
                path.stroke()
            }
        case .pie:
            break
        }
    }

    /// 1, 2, 5 × 10ⁿ above `value`, for round axis labels.
    static func niceCeiling(_ value: Double) -> Double {
        let exponent = pow(10, floor(log10(value)))
        for factor in [1.0, 2.0, 5.0, 10.0] where factor * exponent >= value {
            return factor * exponent
        }
        return 10 * exponent
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }
}
