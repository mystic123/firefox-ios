/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage

private let CancelButtonTitle = NSLocalizedString("Cancel", comment: "Authentication prompt cancel button")
private let LogInButtonTitle  = NSLocalizedString("Log in", comment: "Authentication prompt log in button")

class Authenticator {
    private static let MaxAuthenticationAttempts = 3

    static func handleAuthRequest(viewController: UIViewController, challenge: NSURLAuthenticationChallenge, loginsHelper: LoginsHelper?) -> Deferred<Maybe<LoginData>> {
        // If there have already been too many login attempts, we'll just fail.
        if challenge.previousFailureCount >= Authenticator.MaxAuthenticationAttempts {
            return deferMaybe(LoginDataError(description: "Too many attempts to open site"))
        }

        var credential = challenge.proposedCredential

        // If we were passed an initial set of credentials from iOS, try and use them.
        if let proposed = credential {
            if !(proposed.user?.isEmpty ?? true) {
                if challenge.previousFailureCount == 0 {
                    return deferMaybe(Login.createWithCredential(credential!, protectionSpace: challenge.protectionSpace))
                }
            } else {
                credential = nil
            }
        }

        // If we have some credentials, we'll show a prompt with them.
        if let credential = credential {
            return promptForUsernamePassword(viewController, credentials: credential, protectionSpace: challenge.protectionSpace, loginsHelper: loginsHelper)
        }

        // Otherwise, try to look them up and show the prompt.
        if let loginsHelper = loginsHelper {
            return loginsHelper.getLoginsForProtectionSpace(challenge.protectionSpace).bindQueue(dispatch_get_main_queue()) { res in

                var credentials: NSURLCredential? = nil
                if let logins = res.successValue {

                    // It is possible that we might have duplicate entries since we match against host and scheme://host.
                    // This is a side effect of https://bugzilla.mozilla.org/show_bug.cgi?id=1238103.
                    if logins.count > 1 {
                        credentials = findValidLoginAmongstLogins(logins, forProtectionSpace: challenge.protectionSpace)?.credentials
                        removeMalformedLoginsFromLogins(logins, usingHelper: loginsHelper)
                    }

                    // Found a single entry but the schemes don't match. This is a result of a schemeless entry that we
                    // saved in a previous iteration of the app so we need to migrate it.
                    else if let login = logins[0] where logins.count == 1 && logins[0]?.protectionSpace.`protocol` != challenge.protectionSpace.`protocol` {
                        credentials = login.credentials

                        let new = Login(credential: login.credentials, protectionSpace: challenge.protectionSpace)
                        loginsHelper.updateLoginByGUID(login.guid, new: new, significant: true)
                    }

                    // Found a single entry that matches the scheme and host - good to go.
                    else {
                        credentials = logins[0]?.credentials
                    }
                }

                return self.promptForUsernamePassword(viewController, credentials: credentials, protectionSpace: challenge.protectionSpace, loginsHelper: loginsHelper)
            }
        }

        // No credentials, so show an empty prompt.
        return self.promptForUsernamePassword(viewController, credentials: nil, protectionSpace: challenge.protectionSpace, loginsHelper: nil)
    }

    private static func findValidLoginAmongstLogins(logins: Cursor<LoginData>, forProtectionSpace protectionSpace: NSURLProtectionSpace) -> LoginData? {
        // A valid login is defined as one that matches the challenge protection space and is not malformed
        return logins.filter { login in
            return (login?.protectionSpace.`protocol` == protectionSpace.`protocol`) && !(login?.hasMalformedHostname ?? false)
        } .flatMap { $0 } .first
    }

    private static func removeMalformedLoginsFromLogins(logins: Cursor<LoginData>, usingHelper loginsHelper: LoginsHelper) -> Success {
        let malformedGUIDs: [GUID] = logins.map { login in
            if let login = login where login.hasMalformedHostname {
                return login.guid
            } else {
                return nil
            }
        } .flatMap { $0 }

        return loginsHelper.removeLoginsWithGUIDS(malformedGUIDs)
    }

    private static func promptForUsernamePassword(viewController: UIViewController, credentials: NSURLCredential?, protectionSpace: NSURLProtectionSpace, loginsHelper: LoginsHelper?) -> Deferred<Maybe<LoginData>> {
        if protectionSpace.host.isEmpty {
            print("Unable to show a password prompt without a hostname")
            return deferMaybe(LoginDataError(description: "Unable to show a password prompt without a hostname"))
        }

        let deferred = Deferred<Maybe<LoginData>>()
        let alert: UIAlertController
        let title = NSLocalizedString("Authentication required", comment: "Authentication prompt title")
        if !(protectionSpace.realm?.isEmpty ?? true) {
            let msg = NSLocalizedString("A username and password are being requested by %@. The site says: %@", comment: "Authentication prompt message with a realm. First parameter is the hostname. Second is the realm string")
            let formatted = NSString(format: msg, protectionSpace.host, protectionSpace.realm ?? "") as String
            alert = UIAlertController(title: title, message: formatted, preferredStyle: UIAlertControllerStyle.Alert)
        } else {
            let msg = NSLocalizedString("A username and password are being requested by %@.", comment: "Authentication prompt message with no realm. Parameter is the hostname of the site")
            let formatted = NSString(format: msg, protectionSpace.host) as String
            alert = UIAlertController(title: title, message: formatted, preferredStyle: UIAlertControllerStyle.Alert)
        }

        // Add a button to log in.
        let action = UIAlertAction(title: LogInButtonTitle,
            style: UIAlertActionStyle.Default) { (action) -> Void in
                guard let user = alert.textFields?[0].text, pass = alert.textFields?[1].text else { deferred.fill(Maybe(failure: LoginDataError(description: "Username and Password required"))); return }

                let login = Login.createWithCredential(NSURLCredential(user: user, password: pass, persistence: .ForSession), protectionSpace: protectionSpace)
                deferred.fill(Maybe(success: login))
                loginsHelper?.setCredentials(login)
        }
        alert.addAction(action)

        // Add a cancel button.
        let cancel = UIAlertAction(title: CancelButtonTitle, style: UIAlertActionStyle.Cancel) { (action) -> Void in
            deferred.fill(Maybe(failure: LoginDataError(description: "Save password cancelled")))
        }
        alert.addAction(cancel)

        // Add a username textfield.
        alert.addTextFieldWithConfigurationHandler { (textfield) -> Void in
            textfield.placeholder = NSLocalizedString("Username", comment: "Username textbox in Authentication prompt")
            textfield.text = credentials?.user
        }

        // Add a password textfield.
        alert.addTextFieldWithConfigurationHandler { (textfield) -> Void in
            textfield.placeholder = NSLocalizedString("Password", comment: "Password textbox in Authentication prompt")
            textfield.secureTextEntry = true
            textfield.text = credentials?.password
        }

        viewController.presentViewController(alert, animated: true) { () -> Void in }
        return deferred
    }

}
