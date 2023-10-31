//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalMessaging
import SignalUI

public protocol ConversationInputTextViewDelegate: AnyObject {
    func didPasteAttachment(_ attachment: SignalAttachment?)
    func inputTextViewSendMessagePressed()
    func textViewDidChange(_ textView: UITextView)
}

// MARK: -

protocol ConversationTextViewToolbarDelegate: AnyObject {
    func textViewDidChange(_ textView: UITextView)
    func textViewDidChangeSelection(_ textView: UITextView)
    func textViewDidBecomeFirstResponder(_ textView: UITextView)
}

// MARK: -

class ConversationInputTextView: BodyRangesTextView {

    private lazy var placeholderView = UILabel()
    private var placeholderConstraints: [NSLayoutConstraint]?

    weak var inputTextViewDelegate: ConversationInputTextViewDelegate?
    weak var textViewToolbarDelegate: ConversationTextViewToolbarDelegate?

    var trimmedText: String { textStorage.string.ows_stripped() }
    var untrimmedText: String { textStorage.string }
    private var textIsChanging = false

    required init() {
        super.init()

        backgroundColor = nil
        scrollIndicatorInsets = UIEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)

        isScrollEnabled = true
        scrollsToTop = false
        isUserInteractionEnabled = true

        contentMode = .redraw
        dataDetectorTypes = []

        placeholderView.text = OWSLocalizedString(
            "INPUT_TOOLBAR_MESSAGE_PLACEHOLDER",
            comment: "Placeholder text displayed in empty input box in chat screen."
        )
        placeholderView.textColor = Theme.placeholderColor
        placeholderView.isUserInteractionEnabled = false
        addSubview(placeholderView)

        // We need to do these steps _after_ placeholderView is configured.
        font = .dynamicTypeBody
        textColor = Theme.primaryTextColor
        textAlignment = .natural
        textContainer.lineFragmentPadding = 0
        contentInset = .zero
        setMessageBody(nil, txProvider: databaseStorage.readTxProvider)

        ensurePlaceholderConstraints()
        updatePlaceholderVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: -

    override var defaultTextContainerInset: UIEdgeInsets {
        var textContainerInset = super.defaultTextContainerInset
        textContainerInset.left = 12
        textContainerInset.right = 12

        // If the placeholder view is visible, we need to offset
        // the input container to accommodate for the sticker button.
        if !placeholderView.isHidden {
            let stickerButtonOffset: CGFloat = 30
            if CurrentAppContext().isRTL {
                textContainerInset.left += stickerButtonOffset
            } else {
                textContainerInset.right += stickerButtonOffset
            }
        }

        return textContainerInset
    }

    private func ensurePlaceholderConstraints() {
        // Don't update constraints when MentionInputView sets textContainerInset in its initializer
        // because placeholderView wasn't added yet.
        guard placeholderView.superview != nil else { return }

        if let placeholderConstraints = placeholderConstraints {
            NSLayoutConstraint.deactivate(placeholderConstraints)
        }

        let topInset = textContainerInset.top
        let leftInset = textContainerInset.left
        let rightInset = textContainerInset.right

        placeholderConstraints = [
            placeholderView.autoMatch(.width, to: .width, of: self, withOffset: -(leftInset + rightInset)),
            placeholderView.autoPinEdge(toSuperviewEdge: .left, withInset: leftInset),
            placeholderView.autoPinEdge(toSuperviewEdge: .top, withInset: topInset)
        ]
    }

    private func updatePlaceholderVisibility() {
        placeholderView.isHidden = !textStorage.string.isEmpty
    }

    override var font: UIFont? {
        didSet { placeholderView.font = font }
    }

    override var contentInset: UIEdgeInsets {
        didSet { ensurePlaceholderConstraints() }
    }

    override var textContainerInset: UIEdgeInsets {
        didSet { ensurePlaceholderConstraints() }
    }

    override func setMessageBody(_ messageBody: MessageBody?, txProvider: ((DBReadTransaction) -> Void) -> Void) {
        super.setMessageBody(messageBody, txProvider: txProvider)
        updatePlaceholderVisibility()
        updateTextContainerInset()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { textViewToolbarDelegate?.textViewDidBecomeFirstResponder(self) }
        return result
    }

    var pasteboardHasPossibleAttachment: Bool {
        // We don't want to load/convert images more than once so we
        // only do a cursory validation pass at this time.
        SignalAttachment.pasteboardHasPossibleAttachment() && !SignalAttachment.pasteboardHasText()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            if pasteboardHasPossibleAttachment && !super.disallowsAnyPasteAction() {
                return true
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if pasteboardHasPossibleAttachment {
            // Note: attachment might be nil or have an error at this point; that's fine.
            let attachment = SignalAttachment.attachmentFromPasteboard()
            inputTextViewDelegate?.didPasteAttachment(attachment)
            return
        }

        super.paste(sender)
    }

    // MARK: - UITextViewDelegate

    override func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        textIsChanging = true
        return super.textView(self, shouldChangeTextIn: range, replacementText: text)
    }

    override func textViewDidChange(_ textView: UITextView) {
        super.textViewDidChange(textView)
        textIsChanging = false

        updatePlaceholderVisibility()
        updateTextContainerInset()

        inputTextViewDelegate?.textViewDidChange(self)
        textViewToolbarDelegate?.textViewDidChange(self)
    }

    override func textViewDidChangeSelection(_ textView: UITextView) {
        super.textViewDidChangeSelection(textView)

        textViewToolbarDelegate?.textViewDidChangeSelection(self)
        
        if self.preferences.doRemoveURLTrackers {
            if let url = URL(string: textView.text) {
                var notTrackedURL: URL {
                    if let cleanedURL = removeQueryParamsFromURL(url: url) {
                        return cleanedURL
                    }
                    return url
                }

                if let range = textView.textRange(from: url.absoluteString.entireRange) {
                    textView.replace(range, withText: notTrackedURL.absoluteString)
                }
            }
        }
    }

    // MARK: - Key Commands

    override var keyCommands: [UIKeyCommand]? {
        let keyCommands = super.keyCommands ?? []

        // We don't define discoverability title for these key commands as they're
        // considered "default" functionality and shouldn't clutter the shortcut
        // list that is rendered when you hold down the command key.
        return keyCommands + [
            // An unmodified return can only be sent by a hardware keyboard,
            // return on the software keyboard will not trigger this command.
            // Return, send message
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(unmodifiedReturnPressed(_:))),
            // Alt + Return, inserts a new line
            UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(modifiedReturnPressed(_:))),
            // Shift + Return, inserts a new line
            UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(modifiedReturnPressed(_:)))
        ]
    }

    @objc
    private func unmodifiedReturnPressed(_ sender: UIKeyCommand) {
        Logger.info("unmodifedReturnPressed: \(String(describing: sender.input))")
        inputTextViewDelegate?.inputTextViewSendMessagePressed()
    }

    @objc
    private func modifiedReturnPressed(_ sender: UIKeyCommand) {
        Logger.info("modifedReturnPressed: \(String(describing: sender.input))")

        replace(selectedTextRange ?? UITextRange(), withText: "\n")

        inputTextViewDelegate?.textViewDidChange(self)
        textViewToolbarDelegate?.textViewDidChange(self)
    }
}

extension UITextView {
    func textRange(from nsRange: NSRange) -> UITextRange? {
        let beginning = self.beginningOfDocument
        guard let start = self.position(from: beginning, offset: nsRange.location),
              let end = self.position(from: start, offset: nsRange.length) else {
            return nil
        }
        return self.textRange(from: start, to: end)
    }
}


private func removeQueryParamsFromURL(url: URL) -> URL? {
    let paramsToRemove = ["igshid", "si", "fbclid", "t", "ttclid", "utm_campaign", "utm_source", "utm_medium", "gclid"]
    var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
    let items = components?.queryItems
    components?.queryItems = items?.filter { item in
        !paramsToRemove.contains(item.name)
    }
    return components?.url
}
