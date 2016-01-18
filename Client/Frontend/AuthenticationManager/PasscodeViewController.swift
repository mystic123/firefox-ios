/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import SnapKit

private class PasscodeInputView: UIView {

    var passcodeSize: UInt

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.font = UIConstants.DefaultChromeFont
        return label
    }()

    private lazy var codeInputField: UITextField = {
        let input = UITextField()
        input.keyboardType = UIKeyboardType.NumberPad
        input.font = UIConstants.PasscodeEntryFont
        var placeholder = ""
        input.text = (0..<self.passcodeSize).map { _ in "—" } .joinWithSeparator(" ")
        return input
    }()

    private let centerContainer = UIView()

    init(frame: CGRect, passcodeSize: UInt) {
        self.passcodeSize = passcodeSize
        super.init(frame: frame)

        centerContainer.addSubview(titleLabel)
        centerContainer.addSubview(codeInputField)
        addSubview(centerContainer)

        centerContainer.snp_makeConstraints { make in
            make.center.equalTo(self)
        }

        titleLabel.snp_makeConstraints { make in
            make.centerX.equalTo(centerContainer)
            make.top.equalTo(centerContainer)
            make.bottom.equalTo(codeInputField.snp_top)
        }

        codeInputField.snp_makeConstraints { make in
            make.centerX.equalTo(centerContainer)
            make.bottom.equalTo(centerContainer)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class PasscodeViewController: UIViewController {

    private lazy var pager: UIScrollView  = {
        let scrollView = UIScrollView()
        scrollView.pagingEnabled = true
        scrollView.userInteractionEnabled = false
        return scrollView
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
    }
}
