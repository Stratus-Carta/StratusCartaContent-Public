@IsTest
private class NF_DocumentTest {

    /** Revenue Cloud / Salesforce Contracts REST as the integration user, with real DML where records matter. */
    private class FakeOrg implements NF_RevCloudApi.Responder {
        Id quoteId;
        String envelopeStatus = 'Completed';
        public String respond(String method, String path, String body) {
            Map<String, Object> req = String.isBlank(body) ? new Map<String, Object>() : (Map<String, Object>) JSON.deserializeUntyped(body);
            if (path.startsWith('/query')) return query(EncodingUtil.urlDecode(path.substringAfter('q='), 'UTF-8'));
            if (path == '/actions/standard/createContract') {
                Contract c = new Contract(AccountId = [SELECT QuoteAccountId FROM Quote WHERE Id = :quoteId].QuoteAccountId,
                    StartDate = Date.today(), Status = 'Draft');
                insert c;
                update new Quote(Id = quoteId, ContractId = c.Id);   // as the standard action does
                return JSON.serialize(new List<Object>{ new Map<String, Object>{ 'isSuccess' => true, 'outputValues' => new Map<String, Object>{ 'contractId' => c.Id } } });
            }
            if (path == '/actions/standard/createContractDocumentVersion') {
                return '[{"isSuccess":true,"outputValues":{"documentGenerateRepresentationResponse":{"jobId":"0nn000000000001"}}}]';
            }
            if (path.startsWith('/connect/clm/contract-document-version/')) return '{"jobId":"0nn000000000001"}';
            if (path == '/sobjects/DocumentGenerationProcess') return '{"id":"0nn000000000002"}';
            if (path.startsWith('/sobjects/DocumentGenerationProcess/')) {
                Boolean proposal = path.contains('0nn000000000002');
                return JSON.serialize(new Map<String, Object>{ 'Status' => 'Success', 'ResponseText' => proposal ? '068000000000002' : '068000000000001,068000000000002',
                    'ReferenceObject' => proposal ? (Object) quoteId : null, 'SourceObjectId' => proposal ? null : '0qt000000000001' });
            }
            if (path.startsWith('/sobjects/ContentVersion/') && path.contains('?fields=ContentDocumentId')) return '{"ContentDocumentId":"069000000000001"}';
            if (path == '/sobjects/ContentVersion') return '{"id":"068000000000009"}';
            if (path == '/sobjects/ContentDistribution') return '{"id":"04I000000000001"}';
            if (path.startsWith('/sobjects/ContentDistribution/')) return '{"DistributionPublicUrl":"https://example.com/view"}';
            if (path == '/sobjects/ContentDocumentLink') return '{"id":"06A000000000001"}';
            if (path.startsWith('/connect/e-sign/documents')) {
                return '{"documents":[{"name":"proposal","sourceId":"069000000000001","fileExtension":"pdf","sourceType":"Content"}]}';
            }
            if (path.startsWith('/connect/e-sign/')) return '{}';
            if (path.endsWith('/VersionData')) return 'PDF';
            if (path == '/sobjects/Contact') {
                Contact c = new Contact(AccountId = (Id) req.get('AccountId'), FirstName = (String) req.get('FirstName'),
                    LastName = (String) req.get('LastName'), Email = (String) req.get('Email'));
                insert c;
                return JSON.serialize(new Map<String, Object>{ 'id' => c.Id });
            }
            if (method == 'PATCH' && path.startsWith('/sobjects/')) {
                Id recordId = (Id) path.substringAfterLast('/');
                SObject so = recordId.getSObjectType().newSObject(recordId);
                Map<String, Schema.SObjectField> fields = recordId.getSObjectType().getDescribe().fields.getMap();
                for (String f : req.keySet()) {
                    if (f == 'Status' && recordId.getSObjectType() == Contract.SObjectType) continue;
                    Object v = req.get(f);
                    Schema.DisplayType t = fields.get(f).getDescribe().getType();
                    if (v != null && t == Schema.DisplayType.DATETIME) v = (DateTime) JSON.deserialize('"' + v + '"', DateTime.class);
                    if (v != null && t == Schema.DisplayType.DATE) v = Date.valueOf(String.valueOf(v));
                    if (v != null && t == Schema.DisplayType.DOUBLE) v = Decimal.valueOf(String.valueOf(v));
                    so.put(f, v);
                }
                update so;
                return '';
            }
            return '{}';
        }
        private String query(String soql) {
            List<Object> rows = new List<Object>();
            if (soql.contains('FROM DocumentTemplate')) rows.add(new Map<String, Object>{ 'Id' => '2dt000000000001' });
            if (soql.contains('FROM Contract WHERE SourceQuoteId')) {
                for (Contract c : [SELECT Id FROM Contract WHERE SourceQuoteId = :quoteId]) rows.add(new Map<String, Object>{ 'Id' => c.Id });
            }
            if (soql.contains('FROM ContractDocumentVersion WHERE Id')) {
                rows.add(new Map<String, Object>{ 'Contract' => new Map<String, Object>{ 'SourceQuoteId' => quoteId } });
            }
            if (soql.contains('FROM DocumentEnvelope')) rows.add(new Map<String, Object>{ 'Status' => envelopeStatus });
            if (soql.contains('FROM ContractDocVerContentDoc')) {
                rows.add(new Map<String, Object>{ 'ContentDocument' => new Map<String, Object>{ 'LatestPublishedVersionId' => '068000000000007' } });
            }
            return JSON.serialize(new Map<String, Object>{ 'records' => rows });
        }
    }

    /** DocuSign eSignature REST for the household embedded signing. */
    private class FakeDocuSign implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            String url = req.getEndpoint();
            if (url.endsWith('/oauth/token')) res.setBody('{"access_token":"tok"}');
            else if (url.endsWith('/oauth/userinfo')) res.setBody('{"accounts":[{"account_id":"acc-1","base_uri":"https://demo.docusign.net"}]}');
            else if (url.endsWith('/views/recipient')) res.setBody('{"url":"https://demo.docusign.net/sign/xyz"}');
            else if (url.endsWith('/documents/combined')) res.setBodyAsBlob(Blob.valueOf('%PDF signed'));
            else if (url.endsWith('/envelopes')) res.setBody('{"envelopeId":"env-123"}');
            else res.setBody('{"status":"completed"}');
            return res;
        }
    }

    @TestSetup
    static void setup() {
        Account home = new Account(Name = NF_QuoteService.PROSPECT_PREFIX + ' - 1', ShippingStreet = '350 5th Ave', ShippingCity = 'New York',
            ShippingState = 'NY', ShippingPostalCode = '10001');
        Account biz = new Account(Name = NF_QuoteService.PROSPECT_PREFIX + ' - Globex');
        insert new List<Account>{ home, biz };
        Id pb = Test.getStandardPricebookId();
        Quote hq = new Quote(Name = 'NovaFiber - 350 5th Ave', QuoteAccountId = home.Id, Pricebook2Id = pb, NF_Channel__c = 'Self-Service');
        Quote bq = new Quote(Name = NF_MultiSiteService.QUOTE_PREFIX + 'Globex - 2 sites', QuoteAccountId = biz.Id, Pricebook2Id = pb,
            NF_Channel__c = 'Self-Service');
        insert new List<Quote>{ hq, bq };
        insert new List<QuoteLineItemRecipient>{
            new QuoteLineItemRecipient(Name = 'Site 01 - HQ - 1 Main St', QuoteId = bq.Id, ServiceState = 'NY'),
            new QuoteLineItemRecipient(Name = 'Site 02 - Branch - 2 Main St', QuoteId = bq.Id, ServiceState = 'TX') };
    }

    static NF_JourneyModels.JourneyContext visitor() {
        NF_JourneyModels.JourneyContext c = new NF_JourneyModels.JourneyContext();
        c.isAgent = false;
        return c;
    }

    static NF_JourneyModels.CustomerDetails signer() {
        NF_JourneyModels.CustomerDetails c = new NF_JourneyModels.CustomerDetails();
        c.firstName = 'Jordan';
        c.lastName = 'Rivera';
        c.email = 'jordan@example.com';
        c.phone = '2125550147';
        return c;
    }

    static FakeOrg fake(Id quoteId) {
        NF_JourneyController.agentOverride = false;   // the test user may hold the agent permission
        FakeOrg f = new FakeOrg();
        f.quoteId = quoteId;
        NF_RevCloudApi.responder = f;
        return f;
    }

    @IsTest
    static void householdAgreementFromContractTemplateSignedInSandbox() {
        Quote q = [SELECT Id FROM Quote WHERE Name = 'NovaFiber - 350 5th Ave'];
        fake(q.Id);
        NF_ESignService.settingsOverride = new NF_DocuSign_Settings__c();

        Test.startTest();
        NF_JourneyModels.AgreementState s = NF_DocumentService.generate(q.Id, signer(), visitor());
        Assert.areEqual('Generating', s.status);
        Assert.areEqual('agreement', s.kind);
        Assert.areEqual('0nn000000000001', s.processId);
        Contract c = [SELECT Id, SourceQuoteId, CustomerSignedId, ContractTerm FROM Contract];
        Assert.areEqual(q.Id, c.SourceQuoteId);
        Assert.areEqual(24, c.ContractTerm);
        Assert.areEqual([SELECT Id FROM Contact WHERE Email = 'jordan@example.com'].Id, c.CustomerSignedId);

        s = NF_DocumentService.poll(q.Id, s.processId, visitor());
        Assert.areEqual('Generated', s.status);
        Assert.areEqual('https://example.com/view', s.documentUrl);
        Assert.areEqual('Sandbox', s.provider);

        NF_JourneyModels.SigningSession session = NF_ESignService.start(q.Id, signer(), null, null, visitor());
        Assert.isTrue(session.envelopeId.startsWith('NF-ESIGN-'));
        try {
            NF_ESignService.complete(q.Id, session.envelopeId, signer(), 'Someone Else', visitor());
            Assert.fail('the typed name must match');
        } catch (NF_JourneyModels.JourneyException e) {
            Assert.isTrue(e.getMessage().contains('full name'));
        }
        s = NF_ESignService.complete(q.Id, session.envelopeId, signer(), 'jordan  rivera', visitor());
        Test.stopTest();
        Assert.areEqual('Signed', s.status);
        Assert.areEqual('068000000000002', [SELECT NF_Signed_Document_Id__c FROM Quote WHERE Id = :q.Id].NF_Signed_Document_Id__c);
    }

    @IsTest
    static void businessProposalFromContextDefinitionSentWithSalesforceContracts() {
        Quote q = [SELECT Id FROM Quote WHERE Name LIKE 'NovaFiber Multi-site%'];
        FakeOrg f = fake(q.Id);
        NF_ESignService.contractsESignOverride = true;

        Test.startTest();
        NF_JourneyModels.AgreementState s = (NF_JourneyModels.AgreementState) JSON.deserialize(
            NF_JourneyController.prepareAgreement(q.Id, JSON.serialize(signer()), false).dataJson, NF_JourneyModels.AgreementState.class);
        Assert.areEqual('proposal', s.kind);
        Quote stamped = [SELECT NF_Site_Count__c, NF_State_List__c, NF_Prepared_By__c FROM Quote WHERE Id = :q.Id];
        Assert.areEqual(2, stamped.NF_Site_Count__c);
        Assert.areEqual('NY and TX', stamped.NF_State_List__c);

        s = (NF_JourneyModels.AgreementState) JSON.deserialize(NF_JourneyController.getAgreement(q.Id, s.processId, false).dataJson,
            NF_JourneyModels.AgreementState.class);
        Assert.areEqual('Generated', s.status);
        Assert.areEqual(1, [SELECT COUNT() FROM Contract WHERE SourceQuoteId = :q.Id], 'proposal filed on a contract from the quote');
        Assert.areEqual('Salesforce Contracts', s.provider);

        NF_JourneyModels.SigningSession session = (NF_JourneyModels.SigningSession) JSON.deserialize(
            NF_JourneyController.startSigning(q.Id, JSON.serialize(signer()), null, null, false).dataJson, NF_JourneyModels.SigningSession.class);
        Assert.isTrue(session.envelopeId.startsWith('CLM-'));
        Assert.isNull(session.signingUrl, 'the signatory signs from the DocuSign email');

        f.envelopeStatus = 'Sent';
        s = NF_ESignService.complete(q.Id, session.envelopeId, signer(), null, visitor());
        Assert.areEqual('Sent', s.status);
        Assert.isTrue(s.message.contains('Waiting for Jordan Rivera'));

        f.envelopeStatus = 'Completed';
        s = (NF_JourneyModels.AgreementState) JSON.deserialize(
            NF_JourneyController.completeSigning(q.Id, session.envelopeId, JSON.serialize(signer()), null, false).dataJson, NF_JourneyModels.AgreementState.class);
        Test.stopTest();
        Assert.areEqual('Signed', s.status);
        Assert.areEqual('068000000000007', [SELECT NF_Signed_Document_Id__c FROM Quote WHERE Id = :q.Id].NF_Signed_Document_Id__c);
    }

    static void docuSign() {
        NF_ESignService.settingsOverride = new NF_DocuSign_Settings__c(Enabled__c = true, Integration_Key__c = 'ik', User_Id__c = 'user',
            Account_Id__c = 'acc-1', Certificate_Name__c = 'NF_DocuSign_JWT');
        Test.setMock(HttpCalloutMock.class, new FakeDocuSign());
    }

    @IsTest
    static void householdAgreementOpensDocuSignEmbeddedSigning() {
        Quote q = [SELECT Id FROM Quote WHERE Name = 'NovaFiber - 350 5th Ave'];
        fake(q.Id);
        docuSign();
        // records first (the fake writes them), callouts after Test.startTest
        NF_JourneyModels.AgreementState s = NF_DocumentService.generate(q.Id, signer(), visitor());
        s = NF_DocumentService.poll(q.Id, s.processId, visitor());
        Assert.areEqual('DocuSign', s.provider);

        Test.startTest();
        NF_JourneyModels.SigningSession session = NF_ESignService.start(q.Id, signer(), 'https://site/return', 'https://site', visitor());
        Test.stopTest();
        Assert.areEqual('env-123', session.envelopeId);
        Assert.areEqual('https://demo.docusign.net/sign/xyz', session.signingUrl);
        Assert.areEqual('Sent', [SELECT NF_Signature_Status__c FROM Quote WHERE Id = :q.Id].NF_Signature_Status__c);
    }

    @IsTest
    static void completedDocuSignEnvelopeFilesTheSignedPdf() {
        Quote q = [SELECT Id, QuoteAccountId FROM Quote WHERE Name = 'NovaFiber - 350 5th Ave'];
        insert new Contract(AccountId = q.QuoteAccountId, StartDate = Date.today(), Status = 'Draft', SourceQuoteId = q.Id);
        update new Quote(Id = q.Id, NF_Signature_Status__c = 'Sent', NF_Envelope_Id__c = 'env-123', NF_Signer_Name__c = 'Jordan Rivera',
            NF_Document_Id__c = '068000000000002');
        fake(q.Id);
        docuSign();

        Test.startTest();
        NF_JourneyModels.AgreementState s = NF_ESignService.complete(q.Id, 'env-123', signer(), null, visitor());
        Test.stopTest();
        Assert.areEqual('Signed', s.status);
        Assert.areEqual('068000000000009', [SELECT NF_Signed_Document_Id__c FROM Quote WHERE Id = :q.Id].NF_Signed_Document_Id__c);
    }

    @IsTest
    static void ordersNeedTheSignatureAndExpiredSessionsAreRefused() {
        Quote q = [SELECT Id FROM Quote WHERE Name = 'NovaFiber - 350 5th Ave'];
        fake(q.Id);
        NF_JourneyModels.CustomerDetails c = signer();
        c.acceptedTerms = true;
        c.portalPassword = 'NovaFiber2026';
        NF_JourneyModels.Envelope env = NF_JourneyController.submitOrder(q.Id, JSON.serialize(c), false);
        Assert.isTrue(env.error.contains('sign your service agreement'), env.error);

        try {
            NF_ESignService.complete(q.Id, 'NF-ESIGN-OLD', signer(), 'Jordan Rivera', visitor());
            Assert.fail('nothing was sent');
        } catch (NF_JourneyModels.JourneyException e) {
            Assert.isTrue(e.getMessage().contains('expired'));
        }
        try {
            NF_ESignService.start(q.Id, signer(), null, null, visitor());
            Assert.fail('nothing generated yet');
        } catch (NF_JourneyModels.JourneyException e) {
            Assert.isTrue(e.getMessage().contains('not ready'));
        }
        NF_JourneyModels.CustomerDetails nobody = new NF_JourneyModels.CustomerDetails();
        env = NF_JourneyController.prepareAgreement(q.Id, JSON.serialize(nobody), false);
        Assert.isTrue(env.error.contains('signer'), env.error);
    }
}
