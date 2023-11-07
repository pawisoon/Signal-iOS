//
// Copyright 2016 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import Contacts
import SignalServiceKit

public class ContactCell: UITableViewCell, ReusableTableViewCell {
    public static let reuseIdentifier = "ContactCell"

    public static let kSeparatorHInset: CGFloat = CGFloat(kAvatarDiameter) + 16 + 8

    static let kAvatarSpacing: CGFloat = 6
    static let kAvatarDiameter: UInt = 40

    let contactImageView: AvatarImageView
    let textStackView: UIStackView
    let titleLabel: UILabel
    var subtitleLabel: UILabel

    var contact: Contact?
    var showsWhenSelected: Bool = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        self.contactImageView = AvatarImageView()
        self.textStackView = UIStackView()
        self.titleLabel = UILabel()
        self.titleLabel.font = UIFont.dynamicTypeBody
        self.subtitleLabel = UILabel()
        self.subtitleLabel.font = UIFont.dynamicTypeSubheadline

        super.init(style: style, reuseIdentifier: reuseIdentifier)

        selectionStyle = UITableViewCell.SelectionStyle.none

        textStackView.axis = .vertical
        textStackView.addArrangedSubview(titleLabel)

        contactImageView.autoSetDimensions(to: CGSize(square: CGFloat(ContactCell.kAvatarDiameter)))

        let contentColumns: UIStackView = UIStackView(arrangedSubviews: [contactImageView, textStackView])
        contentColumns.axis = .horizontal
        contentColumns.spacing = ContactCell.kAvatarSpacing
        contentColumns.alignment = .center

        self.contentView.addSubview(contentColumns)
        contentColumns.autoPinEdgesToSuperviewMargins()

        NotificationCenter.default.addObserver(self, selector: #selector(self.didChangePreferredContentSize), name: UIContentSizeCategory.didChangeNotification, object: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func prepareForReuse() {
        accessoryType = .none
        self.subtitleLabel.removeFromSuperview()
    }

    public override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        if showsWhenSelected {
            accessoryType = selected ? .checkmark : .none
        }
    }

    @objc
    private func didChangePreferredContentSize() {
        self.titleLabel.font = UIFont.dynamicTypeBody
        self.subtitleLabel.font = UIFont.dynamicTypeSubheadline
    }

    public func configure(contact: Contact, sortOrder: CNContactSortOrder, subtitleType: SubtitleCellValue, showsWhenSelected: Bool) {

        self.contact = contact
        self.showsWhenSelected = showsWhenSelected

        let cnContact: CNContact?
        if let cnContactId = contact.cnContactId {
            cnContact = contactsManager.cnContact(withId: cnContactId)
        } else {
            cnContact = nil
        }

        if let cnContact {
            titleLabel.attributedText = cnContact.formattedFullName(sortOrder: sortOrder, font: titleLabel.font)
        } else {
            titleLabel.text = contact.fullName
        }

        updateSubtitle(subtitleType: subtitleType, contact: contact)

        var contactImage: UIImage?
        if let cnContact {
            if let avatarImage = contactsManager.avatarImage(forCNContactId: cnContact.identifier) {
                contactImage = avatarImage
            } else if cnContact.imageDataAvailable, let contactImageData = cnContact.imageData {
                contactImage = UIImage(data: contactImageData)
            }
        }
        if contactImage == nil {
            var nameComponents = PersonNameComponents()
            nameComponents.givenName = contact.firstName
            nameComponents.familyName = contact.lastName

            let avatar = databaseStorage.read { transaction in
                Self.avatarBuilder.avatarImage(personNameComponents: nameComponents,
                                               diameterPoints: ContactCell.kAvatarDiameter,
                                               transaction: transaction)
            }
            contactImage = avatar
        }
        contactImageView.image = contactImage
    }

    func updateSubtitle(subtitleType: SubtitleCellValue, contact: Contact) {
        switch subtitleType {
        case .none:
            assert(self.subtitleLabel.superview == nil)
        case .phoneNumber:
            self.textStackView.addArrangedSubview(self.subtitleLabel)

            if let firstPhoneNumber = contact.userTextPhoneNumbers.first {
                self.subtitleLabel.text = firstPhoneNumber
            } else {
                self.subtitleLabel.text = OWSLocalizedString("CONTACT_PICKER_NO_PHONE_NUMBERS_AVAILABLE", comment: "table cell subtitle when contact card has no known phone number")
            }
        case .email:
            self.textStackView.addArrangedSubview(self.subtitleLabel)

            if let firstEmail = contact.emails.first {
                self.subtitleLabel.text = firstEmail
            } else {
                self.subtitleLabel.text = OWSLocalizedString("CONTACT_PICKER_NO_EMAILS_AVAILABLE", comment: "table cell subtitle when contact card has no email")
            }
        }
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        titleLabel.textColor = Theme.primaryTextColor
        subtitleLabel.textColor = Theme.secondaryTextAndIconColor

        OWSTableItem.configureCell(self)
    }
}

fileprivate extension CNContact {
    /**
     * Bold the sorting portion of the name. e.g. if we sort by family name, bold the family name.
     */
    func formattedFullName(sortOrder: CNContactSortOrder, font: UIFont) -> NSAttributedString? {
        let keyToHighlight = sortOrder == .familyName ? CNContactFamilyNameKey : CNContactGivenNameKey

        let boldDescriptor = font.fontDescriptor.withSymbolicTraits(.traitBold)
        let boldAttributes = [
            NSAttributedString.Key.font: UIFont(descriptor: boldDescriptor!, size: 0)
        ]

        if let attributedName = CNContactFormatter.attributedString(from: self, style: .fullName, defaultAttributes: nil) {
            let highlightedName = attributedName.mutableCopy() as! NSMutableAttributedString
            highlightedName.enumerateAttributes(in: highlightedName.entireRange, options: [], using: { (attrs, range, _) in
                if let property = attrs[NSAttributedString.Key(rawValue: CNContactPropertyAttribute)] as? String, property == keyToHighlight {
                    highlightedName.addAttributes(boldAttributes, range: range)
                }
            })
            return highlightedName
        }

        if let emailAddress = self.emailAddresses.first?.value {
            return NSAttributedString(string: emailAddress as String, attributes: boldAttributes)
        }

        if let phoneNumber = self.phoneNumbers.first?.value.stringValue {
            return NSAttributedString(string: phoneNumber, attributes: boldAttributes)
        }

        return nil
    }
}
