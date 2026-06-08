import Cocoa

// MARK: - Live Answer View

final class LiveAnswerView: NSView {
    // UI Elements
    private let questionField = NSTextField()
    private let answerLabel = NSTextField(wrappingLabelWithString: "")
    private let askButton = NSButton(title: "Ask", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let confidenceIndicator = NSView()

    // State
    private let generator = LiveAnswerGenerator.shared
    private var currentAnswer = ""

    // Callbacks
    var onAnswerGenerated: ((AnswerResult) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true

        // Question input field
        questionField.placeholderString = "Ask a question about the meeting..."
        questionField.font = .systemFont(ofSize: 12)
        questionField.bezelStyle = .roundedBezel
        questionField.delegate = self
        questionField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(questionField)

        // Ask button
        askButton.bezelStyle = .rounded
        askButton.target = self
        askButton.action = #selector(askButtonClicked)
        askButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(askButton)

        // Answer label
        answerLabel.font = .systemFont(ofSize: 12)
        answerLabel.textColor = .labelColor
        answerLabel.maximumNumberOfLines = 6
        answerLabel.isSelectable = true
        answerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(answerLabel)

        // Status label
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        // Confidence indicator
        confidenceIndicator.wantsLayer = true
        confidenceIndicator.layer?.cornerRadius = 4
        confidenceIndicator.isHidden = true
        confidenceIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(confidenceIndicator)

        NSLayoutConstraint.activate([
            questionField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            questionField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            questionField.trailingAnchor.constraint(equalTo: askButton.leadingAnchor, constant: -8),
            questionField.heightAnchor.constraint(equalToConstant: 24),

            askButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            askButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            askButton.widthAnchor.constraint(equalToConstant: 50),

            answerLabel.topAnchor.constraint(equalTo: questionField.bottomAnchor, constant: 12),
            answerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            answerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            statusLabel.topAnchor.constraint(equalTo: answerLabel.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),

            confidenceIndicator.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            confidenceIndicator.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
            confidenceIndicator.widthAnchor.constraint(equalToConstant: 8),
            confidenceIndicator.heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    @objc private func askButtonClicked() {
        askQuestion()
    }

    func askQuestion() {
        let question = questionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        askQuestion(question)
    }

    func askQuestion(_ question: String) {
        currentAnswer = ""
        answerLabel.stringValue = ""
        statusLabel.stringValue = "Generating..."
        askButton.isEnabled = false
        confidenceIndicator.isHidden = true

        Task {
            await generator.generateAnswer(
                for: question,
                onToken: { [weak self] token in
                    DispatchQueue.main.async {
                        self?.currentAnswer += token
                        self?.answerLabel.stringValue = self?.currentAnswer ?? ""
                    }
                },
                onComplete: { [weak self] result in
                    DispatchQueue.main.async {
                        self?.handleAnswerComplete(result)
                    }
                }
            )
        }
    }

    private func handleAnswerComplete(_ result: AnswerResult) {
        askButton.isEnabled = true
        statusLabel.stringValue = "\(result.confidence.rawValue) confidence • \(result.formattedDuration)"

        // Show confidence indicator
        confidenceIndicator.isHidden = false
        switch result.confidence {
        case .high:
            confidenceIndicator.layer?.backgroundColor = NSColor.systemGreen.cgColor
        case .medium:
            confidenceIndicator.layer?.backgroundColor = NSColor.systemYellow.cgColor
        case .low:
            confidenceIndicator.layer?.backgroundColor = NSColor.systemOrange.cgColor
        case .none:
            confidenceIndicator.layer?.backgroundColor = NSColor.systemGray.cgColor
        }

        onAnswerGenerated?(result)

        // Record for stats
        generator.recordAnswer(result)
    }

    func clear() {
        questionField.stringValue = ""
        answerLabel.stringValue = ""
        statusLabel.stringValue = ""
        confidenceIndicator.isHidden = true
        currentAnswer = ""
    }

    func setQuestion(_ question: String) {
        questionField.stringValue = question
    }
}

// MARK: - NSTextFieldDelegate

extension LiveAnswerView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            askQuestion()
            return true
        }
        return false
    }
}

// MARK: - Streaming Answer Display

final class StreamingAnswerLabel: NSTextField {
    private var displayLink: CVDisplayLink?
    private var pendingText: [Character] = []
    private var currentText = ""
    private let charsPerFrame = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isEditable = false
        isBordered = false
        backgroundColor = .clear
        font = .systemFont(ofSize: 12)
    }

    func appendText(_ text: String) {
        pendingText.append(contentsOf: text)
        processNextChars()
    }

    private func processNextChars() {
        guard !pendingText.isEmpty else { return }

        // Process characters with slight animation effect
        let toProcess = min(charsPerFrame, pendingText.count)
        let chars = pendingText.prefix(toProcess)
        pendingText.removeFirst(toProcess)

        currentText += String(chars)
        stringValue = currentText

        if !pendingText.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                self?.processNextChars()
            }
        }
    }

    func reset() {
        pendingText.removeAll()
        currentText = ""
        stringValue = ""
    }
}

// MARK: - Quick Answer Buttons

final class QuickAnswerButtonsView: NSView {
    var onQuestionSelected: ((String) -> Void)?

    private let questions = [
        "What was just discussed?",
        "Who is responsible?",
        "What are the next steps?",
        "When is the deadline?"
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        for question in questions {
            let button = NSButton(title: shortLabel(for: question), target: self, action: #selector(buttonClicked(_:)))
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 10)
            button.toolTip = question
            button.setAccessibilityLabel(question)
            stackView.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func shortLabel(for question: String) -> String {
        if question.contains("discussed") { return "Summary" }
        if question.contains("responsible") { return "Owner" }
        if question.contains("next steps") { return "Next" }
        if question.contains("deadline") { return "When" }
        return String(question.prefix(10))
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        if let question = sender.accessibilityLabel() {
            onQuestionSelected?(question)
        }
    }
}
