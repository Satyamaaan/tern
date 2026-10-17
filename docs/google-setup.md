# Set up your own Google OAuth client

Tern is open source and ships without a Google client ID. To read your Gmail, Tern uses a Google
Cloud OAuth client that you create yourself. Only Tern on your Mac and Google ever see it. This takes
about ten minutes and costs nothing.

You need a Google account that can create Cloud projects. A personal Gmail account works. One client
works for every Gmail account you add to Tern, personal and Google Workspace alike.

Tern asks for these permissions:

| Scope | Why |
| --- | --- |
| `https://www.googleapis.com/auth/gmail.modify` | Read, label, archive, trash and send mail. Tern can't permanently delete mail. |
| `openid`, `email`, `profile` | Your address, name and picture, to label the account in Tern. |

These steps follow Google's console as of October 2026. The OAuth pages now live under **Google Auth
Platform** (Overview, Branding, Audience, Clients, Data Access). Older guides call this area the
"OAuth consent screen".

## 1. Create a project

1. Open <https://console.cloud.google.com/projectcreate>. You can also go to **Menu ☰ → IAM & Admin → Create a Project**.
2. Name it, for example `Tern Mail`. You can leave **Location** as it is.
3. Click **Create**. When the notification appears, select the new project. Its name shows in the project picker at the top of the page.

## 2. Enable the Gmail API

1. Open <https://console.cloud.google.com/apis/library/gmail.googleapis.com>, or go to **Menu ☰ → APIs & Services → Library** and search for "Gmail API".
2. Check that your new project is selected, then click **Enable**.

## 3. Set up the consent screen (Branding)

1. Go to **Menu ☰ → Google Auth Platform → Branding**: <https://console.cloud.google.com/auth/branding>.
2. If it says Google Auth Platform isn't configured yet, click **Get started**.
3. **App information:** enter an app name such as `Tern`, choose your email as the **User support email**, then click **Next**.
4. **Audience:** choose **External**, then click **Next**. Pick External even if you use Google Workspace, unless every account you'll add belongs to that one Workspace organization. **Internal** only accepts accounts from your own organization.
5. **Contact information:** enter your email, then click **Next**.
6. **Finish:** tick the box agreeing to the *Google API Services: User Data Policy*, click **Continue**, then click **Create**.

Leave the logo empty. A logo means Google has to review the branding. Until an app is verified, the
consent screen shows the project's domain and not the app name anyway.

## 4. Add the scopes (Data Access)

1. Go to **Google Auth Platform → Data Access**: <https://console.cloud.google.com/auth/scopes>.
2. Click **Add or remove scopes**.
3. Tick these four scopes. Use the filter box to find them.
   - `.../auth/userinfo.email`
   - `.../auth/userinfo.profile`
   - `openid`
   - `https://www.googleapis.com/auth/gmail.modify`, listed under Gmail API. Google marks it as a *restricted* scope.
4. If `gmail.modify` isn't in the list, the Gmail API isn't enabled for this project; go back to step 2. You can also paste the full URL into **Manually add scopes** and click **Add to table**.
5. Click **Update**, then click **Save** at the bottom of the Data Access page.

## 5. Publish the app to Production (Audience)

This step matters. A new app starts in **Testing**. In Testing, Google expires every sign-in **7 days**
after you grant consent: the refresh token stops working and Tern asks you to sign in again every
week. Publishing to Production removes that limit.

1. Go to **Google Auth Platform → Audience**: <https://console.cloud.google.com/auth/audience>.
2. Under **Publishing status**, click **Publish app**, then confirm.
3. The status now reads **In production**. The console may say the app needs verification because `gmail.modify` is a restricted scope. You don't need verification for your own use:
   - An unverified app works for up to 100 users over the project's lifetime. Each user sees a warning screen once, at sign-in (step 8).
   - Don't submit the app for verification. That process is for apps distributed to the public.

If you'd rather stay in Testing, add yourself under **Audience → Test users → Add users**. You'll then
have to reconnect each account in Tern every 7 days.

## 6. Create the Desktop OAuth client (Clients)

1. Go to **Google Auth Platform → Clients**: <https://console.cloud.google.com/auth/clients>.
2. Click **Create client**.
3. Set **Application type** to **Desktop app**. Use **Desktop app**, not "Web application". Tern signs you in through a temporary listener on `127.0.0.1`, which only works with Desktop clients.
4. Name it, for example `Tern on my Mac`.
5. Leave **Use this client for an AI-powered agent** unticked. Google doesn't let you change it later.
6. Click **Create**. There are no redirect URIs to enter for a Desktop client.
7. A dialog shows the **Client ID** (ending in `.apps.googleusercontent.com`) and the **Client secret** (starting with `GOCSPX-`). **Click Download JSON now.** Google shows the full secret only at creation and never again.

If you lose the secret, open the client and click **Add secret**. A client can have two secrets at a
time; delete the old one once Tern uses the new one.

## 7. Give the client to Tern

In Tern's onboarding, or in **Settings → Accounts → Google client**, do one of these:

- Drop the downloaded `client_secret_….json` file onto the window, or
- Paste the **Client ID** and **Client secret**.

Tern stores them in your login Keychain under `dev.tern.mail.oauth-client`. The secret of a Desktop
client isn't truly secret, since anyone with the app could read it. Still, keep it to yourself and
don't commit it to a repository.

## 8. Connect your Gmail accounts

1. In Tern, click **Add account**. Your browser opens Google's sign-in page.
2. Pick the account.
3. Google warns **"This app isn't verified"** (some versions say "Google hasn't verified this app"). It's your own project, so this is expected:
   1. Click **Advanced**.
   2. Click **Go to *your project or domain* (unsafe)**.
4. On the permissions screen, **keep every box ticked**, especially the Gmail one. If you untick Gmail access, Tern stops and asks you to connect again.
5. Click **Continue**. The tab says *You can close this tab and return to Tern*, and the account appears in Tern.

Repeat for each account. Each account's refresh token is stored in the Keychain under
`dev.tern.mail.google`. To disconnect an account, use **Remove account** in Tern. That revokes the
token at Google and deletes it from the Keychain. You can also revoke access at
<https://myaccount.google.com/connections>.

## Good to know

- **Gmail quota.** Projects created on or after 1 May 2026 get 6,000 Gmail quota units per user per minute. Older projects keep 15,000. Tern paces itself to stay under the limit, so the first sync of a large mailbox takes a while. Later syncs only fetch changes and are quick. A Tern account uses only a small part of the per-project daily threshold.
- **Unused clients are deleted.** Google deletes OAuth clients that are inactive for six months and emails you 30 days before. A deleted client can usually be restored within 30 days, from **Clients**. Using Tern counts as activity.
- **Sign-in expires on its own** if you revoke access, change your Google password (for tokens with Gmail scopes), or leave an account unused for six months. Tern then shows the account as needing sign-in; reconnect it.
- **Google Workspace accounts.** An administrator can block apps they haven't approved. You'll then see `admin_policy_enforced` or "access blocked" during sign-in. Ask the administrator to trust your client ID:
  1. In the Admin console, go to **Security → Access and data control → API controls → Manage Third-Party App Access**.
  2. Click **Configured apps → Add app**, and search by your OAuth client ID.
  3. Set access to **Trusted**.
- **"Access blocked: … has not completed the Google verification process".** The app is still in Testing and the account isn't a test user. Either publish to Production (step 5) or add the account under **Audience → Test users**.
- **`redirect_uri_mismatch` or `invalid_client` errors** mean the client isn't of type Desktop app, or the ID or secret was pasted wrong. Create a Desktop client (step 6) and enter it again.
- **"Gmail API has not been used in project … or it is disabled".** Step 2 was skipped or done in another project.

## References

- Configure the OAuth consent screen: <https://developers.google.com/workspace/guides/configure-oauth-consent>
- Manage app audience (Testing vs Production, test users): <https://support.google.com/cloud/answer/15549945>
- Manage OAuth clients (secrets, inactive clients): <https://support.google.com/cloud/answer/15549257>
- Unverified apps and the 100-user cap: <https://support.google.com/cloud/answer/7454865>
- When verification isn't needed (personal use): <https://support.google.com/cloud/answer/13464323>
- OAuth 2.0 for desktop apps (loopback redirect, PKCE): <https://developers.google.com/identity/protocols/oauth2/native-app>
- Gmail API usage limits: <https://developers.google.com/workspace/gmail/api/reference/quota>
- Workspace admins, controlling third-party app access: <https://support.google.com/a/answer/13152743>
