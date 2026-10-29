/**
 * NF_OrderService
 * Checkout: converts the confirmed quote into a Revenue Cloud order and records the customer.
 * Everything runs as REST calls through the NF_RevenueCloud named credential (integration user), so
 * agents and guest visitors are served the same way, synchronously:
 *   1. POST /actions/standard/createOrdersFromQuote  (Revenue Cloud standard action, CreateSingleOrder)
 *   2. only once the order exists: prospect account → customer, bill-to contact, the signed agreement or
 *      proposal as an activated Contract, order stamped with the journey details (sObject REST), so a failed
 *      order leaves nothing half-changed.
 * Visitors must have signed the service agreement first; every multi-site order needs its signed proposal.
 * The order is left in Draft; activation/submission belongs to the decomposition & orchestration phase.
 */
public inherited sharing class NF_OrderService {

    private static final String EMAIL_REGEX = '^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$';
    private static final Map<String, String> ALLOW_DUPLICATES = new Map<String, String>{ 'Sforce-Duplicate-Rule-Header' => 'allowSave=true' };

    public static NF_JourneyModels.OrderResult submit(String quoteId, NF_JourneyModels.CustomerDetails customer,
                                                     NF_JourneyModels.JourneyContext ctx) {
        validateCustomer(customer, ctx);

        List<Quote> qs = [
            SELECT Id, Name, QuoteNumber, Status, QuoteAccountId, QuoteAccount.Name, NF_Channel__c, NF_ServiceabilityRef__c,
                   NF_Signature_Status__c, NF_Signed_Document_Id__c, NF_Signer_Name__c, NF_Signed_At__c
            FROM Quote WHERE Id = :quoteId LIMIT 1
        ];
        if (qs.isEmpty() || qs[0].NF_Channel__c == null || qs[0].Name == NF_QuoteService.WORKSPACE_NAME) {
            throw new NF_JourneyModels.JourneyException('We could not find your quote. Please start again.');
        }
        Quote q = qs[0];
        if (q.Status != 'Draft' || [SELECT COUNT() FROM Order WHERE QuoteId = :q.Id] > 0) {
            throw new NF_JourneyModels.JourneyException('This quote has already been ordered.');
        }
        Boolean isProspect = (q.QuoteAccount?.Name ?? '').startsWith(NF_QuoteService.PROSPECT_PREFIX);
        if (!ctx.isAgent && !isProspect) {
            throw new NF_JourneyModels.JourneyException('This quote cannot be ordered online. Please contact NovaFiber.');
        }
        Boolean business = NF_DocumentService.isBusiness(q);
        Boolean signed = q.NF_Signature_Status__c == NF_DocumentService.STATUS_SIGNED;
        if (!signed && (business || !ctx.isAgent)) {
            throw new NF_JourneyModels.JourneyException(business
                ? 'Please sign the proposal before placing the order.'
                : 'Please review and sign your service agreement before placing the order.');
        }

        // 1. Revenue Cloud: quote → order
        OrderRef created = createOrderFromQuote(q, ctx);

        // 2. Customer records, now that the order exists
        String fullName = customer.firstName.trim() + ' ' + customer.lastName.trim();
        if (isProspect) {
            // A household is named after the customer; a multi-site business keeps its business name.
            String accountName = q.Name.startsWith(NF_MultiSiteService.QUOTE_PREFIX)
                ? q.QuoteAccount.Name.removeStart(NF_QuoteService.PROSPECT_PREFIX + ' - ')
                : fullName;
            NF_RevCloudApi.patch('/sobjects/Account/' + q.QuoteAccountId,
                new Map<String, Object>{ 'Name' => accountName, 'Phone' => customer.phone },
                'Prospect account → customer ' + accountName, ALLOW_DUPLICATES);
            NF_Trace.rec('UPDATE', 'Account', q.QuoteAccountId, 'prospect → customer');
        }
        Id contactId = findOrCreateContact(q.QuoteAccountId, customer);

        Date installDate = customer.preferredInstallDate != null ? customer.preferredInstallDate : Date.today().addDays(7);
        String bookingToken = NF_SchedulingService.newToken();
        Id contractId = signed ? activateContract(q, contactId, business) : null;
        String contractNumber = contractId == null ? null      // read now: no callouts after the DML below
            : String.valueOf(NF_RevCloudApi.get('/sobjects/Contract/' + contractId + '?fields=ContractNumber', 'Contract number').get('ContractNumber'));
        // Only fields the integration user can update over the API (ShipToContactId and
        // CustomerAuthorizedDate are hidden from it by field-level security in this org).
        NF_RevCloudApi.patch('/sobjects/Order/' + created.orderId, new Map<String, Object>{
            'NF_Channel__c' => ctx.channel,
            'NF_ServiceabilityRef__c' => q.NF_ServiceabilityRef__c,
            'BillToContactId' => contactId,
            'CustomerAuthorizedById' => contactId,
            'NF_Booking_Token__c' => bookingToken,
            'ContractId' => contractId,
            'Description' => 'Preferred install date: ' + installDate.format()
                + (ctx.isAgent ? '\nCaptured by agent ' + UserInfo.getName() : '\nCaptured via self-service')
        }, 'Order ' + created.orderNumber + ' · channel, contacts, install date', null);
        NF_Trace.rec('UPDATE', 'Order', created.orderId, 'channel, contacts, install date');

        // 3. Fulfillment: activate the order and submit it to Dynamic Revenue Orchestrator
        NF_DroService.Submission dro = NF_DroService.submit(created.orderId, q.Id);
        NF_JourneyModels.QuoteSummary totals = NF_QuoteService.summarize(q.Id);
        NF_DroService.recordSubmission(created.orderId, dro);   // DML last: no callouts after this

        // 4. My NovaFiber login to track the order (password hashed, never kept)
        String portalUsername;
        if (String.isNotBlank(customer.portalPassword)) {
            portalUsername = NF_PortalService.register(q.QuoteAccountId, contactId, customer.email, customer.portalPassword);
        } else if (NF_PortalService.exists(customer.email)) {
            NF_PortalService.linkContact(customer.email, q.QuoteAccountId, contactId);
            portalUsername = customer.email.trim().toLowerCase();
        }
        customer.portalPassword = null;

        Order o = [SELECT Id, OrderNumber, Status, AccountId, Account.Name, NF_Fulfillment_Status__c FROM Order WHERE Id = :created.orderId];

        NF_JourneyModels.OrderResult r = new NF_JourneyModels.OrderResult();
        r.orderId = o.Id;
        r.orderNumber = o.OrderNumber;
        r.status = o.Status;
        r.accountId = o.AccountId;
        r.accountName = o.Account.Name;
        r.quoteId = q.Id;
        r.monthlyTotal = totals.monthlyTotal;
        r.oneTimeTotal = totals.oneTimeTotal;
        r.installDate = installDate;
        r.fulfillmentStatus = o.NF_Fulfillment_Status__c;
        r.submittedToFulfillment = dro.submitted;
        r.portalUsername = portalUsername;
        r.bookingToken = bookingToken;
        r.contractId = contractId;
        r.contractNumber = contractNumber;
        return r;
    }

    /**
     * The quote's Salesforce Contracts contract (created with the agreement / proposal) becomes the customer's
     * activated contract: signer, signed date, the signed PDF in its files. Never blocks the order.
     */
    private static Id activateContract(Quote q, Id contactId, Boolean business) {
        try {
            Id contractId = NF_DocumentService.contractOf(q.Id) ?? NF_DocumentService.ensureContract(q, contactId);
            NF_RevCloudApi.patch('/sobjects/Contract/' + contractId, new Map<String, Object>{
                'CustomerSignedId' => contactId, 'CustomerSignedDate' => (q.NF_Signed_At__c ?? DateTime.now()).date(),
                'CustomerSignedTitle' => business ? 'Authorised signatory' : 'Account holder'
            }, 'Contract · signed by ' + q.NF_Signer_Name__c, null);
            if (String.isNotBlank(q.NF_Signed_Document_Id__c)) {
                Map<String, Object> cv = NF_RevCloudApi.get('/sobjects/ContentVersion/' + q.NF_Signed_Document_Id__c + '?fields=ContentDocumentId',
                    'Signed PDF document');
                try {
                    NF_RevCloudApi.post('/sobjects/ContentDocumentLink', new Map<String, Object>{
                        'ContentDocumentId' => cv.get('ContentDocumentId'), 'LinkedEntityId' => contractId, 'ShareType' => 'V'
                    }, 'Signed PDF → contract files');
                } catch (NF_RevCloudApi.RevCloudException e) {
                    // already filed on the contract (DocuSign / Salesforce Contracts store it there)
                }
            }
            NF_RevCloudApi.patch('/sobjects/Contract/' + contractId, new Map<String, Object>{ 'Status' => 'Activated' },
                'Contract · activate', null);
            NF_Trace.rec('UPDATE', 'Contract', contractId, 'activated');
            return contractId;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'NF contract for quote ' + q.QuoteNumber + ' failed: ' + e.getMessage());
            NF_Trace.note('APEX', 'Contract not activated', e.getMessage());
            return null;
        }
    }

    private class OrderRef {
        Id orderId;
        String orderNumber;
    }

    private static OrderRef createOrderFromQuote(Quote q, NF_JourneyModels.JourneyContext ctx) {
        // createOrdersFromQuote (API 65+, replaces the deprecated createOrderFromQuote). CreateSingleOrder
        // creates the header and lines synchronously. Needs "Advanced Order Creation From Quote" in Revenue Settings.
        List<Object> results;
        try {
            results = NF_RevCloudApi.postList('/actions/standard/createOrdersFromQuote', new Map<String, Object>{
                'inputs' => new List<Object>{ new Map<String, Object>{
                    'quoteId' => q.Id, 'orderCreationMethod' => 'CreateSingleOrder' } }
            }, 'Revenue Cloud · create order from Quote ' + q.QuoteNumber);
        } catch (NF_RevCloudApi.RevCloudException e) {   // the action answers HTTP 400 when it fails
            System.debug(LoggingLevel.ERROR, 'NF createOrdersFromQuote failed for ' + q.QuoteNumber + ': ' + e.getMessage());
            throw new NF_JourneyModels.JourneyException('We could not place your order right now. '
                + (ctx.isAgent ? e.getMessage() : 'Please try again.'));
        }
        Map<String, Object> result = results.isEmpty() || !(results[0] instanceof Map<String, Object>)
            ? new Map<String, Object>() : (Map<String, Object>) results[0];
        Map<String, Object> outputs = result.get('outputValues') instanceof Map<String, Object>
            ? (Map<String, Object>) result.get('outputValues') : new Map<String, Object>();
        List<Object> orderIds = outputs.get('orderIds') instanceof List<Object> ? (List<Object>) outputs.get('orderIds') : new List<Object>();
        if (result.get('isSuccess') != true || orderIds.isEmpty()) {
            String detail = NF_RevCloudApi.firstError(result.get('errors'));
            System.debug(LoggingLevel.ERROR, 'NF createOrdersFromQuote failed for ' + q.QuoteNumber + ': ' + detail);
            throw new NF_JourneyModels.JourneyException('We could not place your order right now. '
                + (ctx.isAgent ? detail : 'Please try again.'));
        }
        OrderRef ref = new OrderRef();
        ref.orderId = (Id) String.valueOf(orderIds[0]);
        ref.orderNumber = [SELECT OrderNumber FROM Order WHERE Id = :ref.orderId].OrderNumber;
        NF_Trace.rec('INSERT', 'Order', ref.orderId, 'created by createOrdersFromQuote');
        return ref;
    }

    private static Id findOrCreateContact(Id accountId, NF_JourneyModels.CustomerDetails cust) {
        String email = cust.email.trim().toLowerCase();
        List<Contact> existing = [SELECT Id FROM Contact WHERE AccountId = :accountId AND Email = :email LIMIT 1];
        if (!existing.isEmpty()) return existing[0].Id;
        Map<String, Object> res = NF_RevCloudApi.post('/sobjects/Contact', new Map<String, Object>{
            'AccountId' => accountId, 'FirstName' => cust.firstName.trim(), 'LastName' => cust.lastName.trim(),
            'Email' => email, 'Phone' => cust.phone
        }, 'Bill-to / ship-to contact', ALLOW_DUPLICATES);
        if (res.get('id') == null) {
            throw new NF_JourneyModels.JourneyException('We could not save your contact details. Please try again.');
        }
        Id contactId = (Id) String.valueOf(res.get('id'));
        NF_Trace.rec('INSERT', 'Contact', contactId, 'bill-to / ship-to contact');
        return contactId;
    }

    public static void validateCustomer(NF_JourneyModels.CustomerDetails c, NF_JourneyModels.JourneyContext ctx) {
        if (c == null || String.isBlank(c.firstName) || String.isBlank(c.lastName)) {
            throw new NF_JourneyModels.JourneyException('Please enter your first and last name.');
        }
        if (String.isBlank(c.email) || !Pattern.matches(EMAIL_REGEX, c.email.trim())) {
            throw new NF_JourneyModels.JourneyException('Please enter a valid email address.');
        }
        String digits = c.phone == null ? '' : c.phone.replaceAll('[^0-9]', '');
        if (digits.length() < 10) {
            throw new NF_JourneyModels.JourneyException('Please enter a valid phone number.');
        }
        if (c.preferredInstallDate != null && c.preferredInstallDate < Date.today().addDays(1)) {
            throw new NF_JourneyModels.JourneyException('Installation can be scheduled from tomorrow onwards.');
        }
        if (!ctx.isAgent && c.acceptedTerms != true) {
            throw new NF_JourneyModels.JourneyException('Please accept the terms of service to continue.');
        }
        // My NovaFiber login: customers choose a password (unless they already have a login); agents may set one.
        if (String.isNotBlank(c.portalPassword) || (!ctx.isAgent && !NF_PortalService.exists(c.email))) {
            NF_PortalService.checkPasswordRules(c.portalPassword);
        }
    }
}
