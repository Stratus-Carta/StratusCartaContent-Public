# Post-Deployment Procedure — Quote to Order Complete Event

Run these steps after deploying this project to a **new Revenue Cloud test org**. Do them in this order. Steps 2–4 must come before step 5, because the product index will not build until the languages match.

## 0. Request a Revenue Cloud test org (if you don't have one)

1. Open the Salesforce free trials page: <https://developer.salesforce.com/free-trials/comparison/communications-cloud>
2. Select **Communications Cloud Free Trial on Salesforce Platform**. It is powered by Revenue Cloud and comes fully configured with sample data and feature discoverability navigation.
3. Fill in the sign-up form and activate the org from the welcome email.
4. Note the org's My Domain URL (`https://<mydomain>.my.salesforce.com`). You need it in step 1.

## 1. Deploy the metadata

```bash
sf org login web --alias "<org alias>" --instance-url https://<mydomain>.my.salesforce.com
sf project deploy start --manifest manifest/package.xml --target-org "<org alias>"
```

Flows deploy as **Draft**. Activate `Lock_Quote_On_Order_Completion` manually in Setup → Flows when you are ready to test.

## 2. Enable record locking and unlocking in Apex

The project needs `Approval.lock` / `Approval.unlock` (for example, `scripts/apex/unlockQuoteAndDeleteOrders.apex`). Without this setting, Apex fails with:

> `System.NoAccessException: Apex approval lock/unlock api preference not enabled`

- **Automatic:** the deploy in step 1 sets this through `force-app/main/default/settings/Apex.settings-meta.xml` (`enableApexApprovalLockUnlock = true`).
- **Manual check:** Setup → **Process Automation Settings** → make sure **Enable record locking and unlocking in Apex** is checked → **Save**.

## 3. Set the org default language to English

Product Catalog Management search indexing only supports **English (en_US)**. The index default language must match the org-wide default language. If they differ, Create Full Index fails with:

> `Specify a language that matches the org-wide default language.`

1. Setup → **Company Information** → **Edit**.
2. **Default Language** = `English`. Optionally, set **Default Locale** = `English (United States)`.
3. **Save**.
4. Optionally, set your own user's **Language** to English (Setup → Users → your user, or Settings → Language & Time Zone).

To verify:

```bash
sf data query -o "<org alias>" -q "SELECT LanguageLocaleKey, DefaultLocaleSidKey FROM Organization"
sf api request rest "/services/data/v65.0/connect/pcm/index/setting" -o "<org alias>"
```

`LanguageLocaleKey` must equal the index `defaultLanguage` (`en_US`).

## 4. Sync pricing data

1. Setup → Quick Find → **Salesforce Pricing Setup**.
2. Click **Sync Pricing Data** and wait for it to complete.

This refreshes the pricing decision tables (Price Book Entries, adjustments, tiers, etc.). To check the result, go to Setup → **Decision Tables**. Each active table should show refresh status **Completed** with a recent sync date. If one shows an error, open it and click **Refresh**.

## 5. Build the product search index

1. App Launcher → **Product Catalog Management** → **Index and Search Configuration** (Index Summary).
2. Confirm the index settings: language = English, and the searchable/facetable fields are what you need.
3. Click **Create Full Index** and wait until the status is completed.

Rebuild the index whenever product data or search configuration changes.

## 6. Enable the completion email

When the conversion completes, the flow sends the Quote Owner a bell notification and an email in English (subject `Quote <QuoteNumber> - Quote to Order conversion completed`). The flow runs as the **Automated Process user**, and the email is sent as the **Default Workflow User** (`senderType = DefaultWorkflowUser`).

How the email action (`Send_Completion_Email`, Send Email / `emailSimple`) is set up, and why:

- **Recipient:** `emailAddresses = {!Get_Quote.Owner:User.Email}`. `recipientId` accepts only a Lead, Contact or Person Account, not a User. Passing the owner's User Id fails with `0 recipients`. `Owner:User` is needed because `Quote.OwnerId` can be a User or a Group (queue). A Quote owned by a queue has no owner email, and the action fails with `0 recipients`.
- **No activity logging:** `logEmailOnSend` is not set. Logging an email sent to a User fails with `saveAsActivity must be false when sending mail to users`.
- **No email template:** `emailTemplateId` requires `recipientId`, so the Send Email action cannot use a template when the recipient is a User. Subject and body come from the flow's text templates `EmailSubject` and `EmailBody`. To use an Email Template instead, replace the action with an **Email Alert** on Quote (recipient = Record Owner).

1. Setup → **Process Automation Settings** → make sure **Default Workflow User** is set to an active user with a valid email address → **Save**. This user is the email sender.
2. Setup → **Deliverability** → **Access level** = `All email` → **Save**. New trial orgs often start with `System email only`. With that setting, the flow runs without an error but no email is sent.
3. Optional: set the email address of the Automated Process user. Platform event flows run as this user, and system emails such as flow error emails use this address. Create an Org-Wide Email Address first. The field in step 4 only accepts an address from this list. Typing any other email fails with `Error: You must enter a valid value`.
   1. Setup → **Organization-Wide Addresses** → **Add** (in the *Organization-Wide Email Addresses* section).
   2. **Display Name**, for example `Quote to Order Notifications`, and **Email Address**, the sender you want.
   3. **Purpose** = `User Selection and Default No-Reply Address`.
   4. Select **Allow All Profiles to Use this From Address**, or at least include **System Administrator**.
   5. **Save**, then open the verification email sent to that address and click the link. The status must be **Verified**. Until then, Setup shows `WARNING: A VERIFIED email address is needed for: Default No-Reply Address`. This is expected and clears once the address is verified. If the email does not arrive, check the spam folder.
4. Setup → **Process Automation Settings** → **Automated Process User Email Address**: enter the verified address from step 3 → **Save**.
5. Make sure the Quote Owner's user record has a valid email address.

### Troubleshooting the completion email

If the flow runs without an error but the email does not arrive:

1. **Check that Salesforce sent it.** Platform event flows run as the Automated Process user, so add a debug log for that user. Setup → **Debug Logs** → **New**, Traced Entity Type = `Automated Process`. Or use the CLI:

   ```bash
   sf data query -o "<org alias>" -q "SELECT Id FROM User WHERE Alias = 'autoproc'"
   sf data query -o "<org alias>" --use-tooling-api -q "SELECT Id, DeveloperName FROM DebugLevel"
   sf data create record -o "<org alias>" --use-tooling-api -s TraceFlag -v "TracedEntityId=<autoproc user Id> DebugLevelId=<DebugLevel Id> LogType=USER_DEBUG ExpirationDate=<UTC datetime, max 24h ahead>"
   ```

   Convert a Quote, then open the `Platform Event Process` log. The line `WF_EMAIL_SENT|Reference:emailSimple|Recipients:<address>` means Salesforce sent the email.
2. **Gmail delivery is slow.** In testing, emails to `@gmail.com` addresses arrived with a long delay or not at all, while the same email to a Yahoo address arrived quickly. The sender address is an `@gmail.com` address, but Salesforce servers send the email, and Gmail treats such mail with suspicion. For testing, use a non-Gmail email on the Quote Owner's user record. For production, send from a domain you control: add `include:_spf.salesforce.com` to the domain's SPF record, set up a DKIM key in Setup → **DKIM Keys**, create a verified Org-Wide Email Address on that domain, and set the email action to `senderType = OrgWideEmailAddress`.
3. **If it was sent, the problem is delivery.** Check the inbox's Spam and All Mail folders, then Setup → **Email Log Files** → request a log for the time of the test. The log shows whether the receiving server accepted, deferred or bounced the message.
4. **To test the email action outside the flow**, call it as your own user with the same parameters:

   ```bash
   sf api request rest "/services/data/v66.0/actions/standard/emailSimple" -X POST -o "<org alias>" --body @email.json
   ```

   with `email.json`:

   ```json
   {"inputs":[{"emailAddresses":"<owner email>","emailSubject":"Test","emailBody":"Test","senderType":"DefaultWorkflowUser","useLineBreaks":true}]}
   ```

## 7. Smoke test

- Activate the flow `Lock_Quote_On_Order_Completion`. It is triggered by the `QuoteToOrderCompletedEvent` platform event.
- Create a Quote with products and convert it to an Order.
- When the conversion completes, check that the Quote is locked, that a `QuoteToOrderInspect__c` record was created, that the `QuoteConvertedToOrder` notification was received, and that the Quote Owner received the completion email.
- The email is not logged as an activity on the Quote. Salesforce does not allow saving an email to a User as an activity (`saveAsActivity must be false when sending mail to users`). Check the Quote Owner's inbox instead.
- Inspect the records created for the Quote. Replace the Id with your Quote Id:

  ```sql
  SELECT Id, SequenceNumber__c, Order__c, OrderStatus__c, Quote__c, QuoteStatus__c
  FROM QuoteToOrderInspect__c
  WHERE Quote__c = '{QuoteId from your Quote}'
  ORDER BY SequenceNumber__c
  ```

  ```bash
  sf data query -o "<org alias>" -q "SELECT Id, SequenceNumber__c, Order__c, OrderStatus__c, Quote__c, QuoteStatus__c FROM QuoteToOrderInspect__c WHERE Quote__c = '<Quote Id>' ORDER BY SequenceNumber__c"
  ```
- To reset test data, run `scripts/apex/unlockQuoteAndDeleteOrders.apex`.
