import Cocoa

// MARK: - Prediction List View

final class PredictionListView: NSView {
    private var predictions: [Prediction] = []
    private var predictionViews: [PredictionItemView] = []
    private let stackView = NSStackView()
    private let headerLabel = NSTextField(labelWithString: "Predicted Questions")

    var onPredictionSelected: ((Prediction) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        // Header
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        // Stack view for predictions
        stackView.orientation = .vertical
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor),

            stackView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }

    func updatePredictions(_ newPredictions: [Prediction]) {
        predictions = newPredictions

        // Clear existing views
        for view in predictionViews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        predictionViews.removeAll()

        // Add new views
        for prediction in predictions.prefix(3) {
            let itemView = PredictionItemView(prediction: prediction)
            itemView.onTap = { [weak self] in
                self?.onPredictionSelected?(prediction)
            }
            stackView.addArrangedSubview(itemView)
            predictionViews.append(itemView)
        }

        // Show empty state if no predictions
        if predictions.isEmpty {
            headerLabel.stringValue = "No predictions yet..."
        } else {
            headerLabel.stringValue = "Predicted Questions"
        }
    }
}

// MARK: - Single Prediction Item View

final class PredictionItemView: NSView {
    private let prediction: Prediction
    private let questionLabel = NSTextField(wrappingLabelWithString: "")
    private let confidenceIndicator = NSView()
    private let categoryLabel = NSTextField(labelWithString: "")

    var onTap: (() -> Void)?

    init(prediction: Prediction) {
        self.prediction = prediction
        super.init(frame: .zero)
        setupUI()
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Question label
        questionLabel.font = .systemFont(ofSize: 11)
        questionLabel.textColor = .labelColor
        questionLabel.maximumNumberOfLines = 2
        questionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(questionLabel)

        // Confidence indicator
        confidenceIndicator.wantsLayer = true
        confidenceIndicator.layer?.cornerRadius = 2
        confidenceIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(confidenceIndicator)

        // Category label
        categoryLabel.font = .systemFont(ofSize: 9)
        categoryLabel.textColor = .tertiaryLabelColor
        categoryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(categoryLabel)

        NSLayoutConstraint.activate([
            confidenceIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            confidenceIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            confidenceIndicator.widthAnchor.constraint(equalToConstant: 4),
            confidenceIndicator.heightAnchor.constraint(equalToConstant: 24),

            questionLabel.leadingAnchor.constraint(equalTo: confidenceIndicator.trailingAnchor, constant: 8),
            questionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            questionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            categoryLabel.leadingAnchor.constraint(equalTo: questionLabel.leadingAnchor),
            categoryLabel.topAnchor.constraint(equalTo: questionLabel.bottomAnchor, constant: 2),
            categoryLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])

        // Click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(click)
    }

    private func configure() {
        questionLabel.stringValue = prediction.question
        categoryLabel.stringValue = "\(prediction.category.rawValue) • \(prediction.confidenceLabel)"

        // Confidence color
        let color: NSColor
        switch prediction.confidence {
        case 8...10:
            color = .systemGreen
        case 6...7:
            color = .systemYellow
        default:
            color = .systemGray
        }
        confidenceIndicator.layer?.backgroundColor = color.cgColor
    }

    @objc private func handleTap() {
        onTap?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedControlColor.withAlphaComponent(0.3).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

// MARK: - Answer Popup

final class AnswerPopupController {
    static let shared = AnswerPopupController()

    private var popover: NSPopover?

    func showAnswer(for prediction: Prediction, relativeTo view: NSView) {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 120)
        popover.behavior = .transient

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 120))

        let label = NSTextField(wrappingLabelWithString: prediction.answer)
        label.font = .systemFont(ofSize: 12)
        label.frame = NSRect(x: 12, y: 12, width: 256, height: 96)
        contentView.addSubview(label)

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyAnswer(_:)))
        copyButton.frame = NSRect(x: 200, y: 8, width: 60, height: 24)
        copyButton.bezelStyle = .inline
        copyButton.setAccessibilityLabel(prediction.answer)
        contentView.addSubview(copyButton)

        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = contentView

        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        self.popover = popover
    }

    @objc private func copyAnswer(_ sender: NSButton) {
        if let answer = sender.accessibilityLabel() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer, forType: .string)
        }
        popover?.close()
    }
}
