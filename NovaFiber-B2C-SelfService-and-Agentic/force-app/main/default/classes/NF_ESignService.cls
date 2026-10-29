/**
 * NF_ESignService
 * Signs the generated agreement or proposal (NF_DocumentService) before the order is placed.
 *
 *   Household agreement → DocuSign embedded signing in checkout (the customer is on the page):
 *       JWT grant signed by the Salesforce certificate NF_DocuSign_JWT (NF_DocuSign_Settings__c) → envelope from the contract's generated PDF, sign-here / date tabs on
 *       the template anchors [[SIGN_CUSTOMER]] / [[DATE_CUSTOMER]] → recipient view shown in the page → on return
 *       the envelope must be "completed" (then the customer moves on; SignedPdfJob files the signed PDF on the contract).
 *       The JWT access token is reused from Platform Cache for its lifetime.
 *   Business proposal → Salesforce Contracts e-signature (native): POST /connect/e-sign/signature-requests/
 *       {contract}/envelope/send emails the authorised signatory through the org's DocuSign connection
 *       (Electronic Signature Configuration); DocumentEnvelope tracks it and the status is synced on demand.
 *   Sandbox → when DocuSign is not connected yet: typed-name e-signature with consent, recorded on the quote.
 *
 * The quote tracks it: NF_Signature_Status__c Generated → Sent → Signed, NF_Envelope_Id__c, NF_Signed_Document_Id__c,
 * NF_Signed_At__c, NF_Signer_Name__c.
 */
public without sharing class NF_ESignService {

    public static final String PROVIDER_DOCUSIGN = 'DocuSign';
    public static final String PROVIDER_CONTRACTS = 'Salesforce Contracts';
    public static final String PROVIDER_SANDBOX = 'Sandbox';
    private static final String SANDBOX_PREFIX = 'NF-ESIGN-';
    private static final String CONTRACTS_PREFIX = 'CLM-';
    @TestVisible private static NF_DocuSign_Settings__c settingsOverride;
    @TestVisible private static Boolean contractsESignOverride;

    public static String provider(Quote q) {
        if (NF_DocumentService.isBusiness(q)) return contractsESignReady() ? PROVIDER_CONTRACTS : PROVIDER_SANDBOX;
        return docuSignReady() ? PROVIDER_DOCUSIGN : PROVIDER_SANDBOX;
    }

    private static NF_DocuSign_Settings__c settings() {
        return settingsOverride ?? NF_DocuSign_Settings__c.getOrgDefaults();
    }

    private static Boolean docuSignReady() {
        NF_DocuSign_Settings__c s = settings();
        return s != null && s.Enabled__c == true && String.isNotBlank(s.Integration_Key__c) && String.isNotBlank(s.User_Id__c)
            && String.isNotBlank(s.Account_Id__c);
    }

    /** Salesforce Contracts e-signature is ready once its DocuSign callout named credential is configured. */
    private static Boolean contractsESignReady() {
        if (contractsESignOverride != null) return contractsESignOverride;
        try {
            return [SELECT COUNT() FROM ESignatureConfig WHERE ConfigType = 'CalloutNamedCredential' AND Vendor = 'DocuSign'] > 0;
        } catch (Exception e) {
            return false;
        }
    }

    // ── Public API ───────────────────────────────────────────────────────────

    /** Sends the generated document for signature and returns how the signer signs it now. */
    public static NF_JourneyModels.SigningSession start(String quoteId, NF_JourneyModels.CustomerDetails signer, String returnUrl,
                                                        String pageOrigin, NF_JourneyModels.JourneyContext ctx) {
        Quote q = NF_DocumentService.loadQuote(quoteId, ctx);
        if (q.NF_Signature_Status__c != NF_DocumentService.STATUS_GENERATED && q.NF_Signature_Status__c != NF_DocumentService.STATUS_SENT) {
            throw new NF_JourneyModels.JourneyException('The document is not ready to sign yet.');
        }
        String name = NF_DocumentService.fullName(signer);
        if (String.isBlank(name) || String.isBlank(signer?.email)) {
            throw new NF_JourneyModels.JourneyException('Please enter the signer\'s name and email first.');
        }
        NF_JourneyModels.SigningSession s = new NF_JourneyModels.SigningSession();
        s.signerName = name;
        s.signerEmail = signer.email.trim().toLowerCase();
        s.provider = provider(q);
        Boolean resend = q.NF_Signature_Status__c == NF_DocumentService.STATUS_SENT && String.isNotBlank(q.NF_Envelope_Id__c);

        if (s.provider == PROVIDER_DOCUSIGN) {
            DocuSign ds = new DocuSign(settings());
            String envelopeId = resend && !q.NF_Envelope_Id__c.startsWith(SANDBOX_PREFIX) ? q.NF_Envelope_Id__c : null;
            if (envelopeId == null) {
                Blob pdf = NF_RevCloudApi.getBlob('/sobjects/ContentVersion/' + q.NF_Document_Id__c + '/VersionData', 'Generated agreement PDF for DocuSign');
                envelopeId = ds.createEnvelope(NF_DocumentService.title(q), pdf, name, s.signerEmail, q.Id);
            }
            s.envelopeId = envelopeId;
            s.signingUrl = ds.recipientView(envelopeId, name, s.signerEmail, q.Id, returnUrl, pageOrigin);
        } else if (s.provider == PROVIDER_CONTRACTS) {
            Id contractId = NF_DocumentService.contractOf(q.Id);
            s.envelopeId = CONTRACTS_PREFIX + contractId;
            if (!resend) sendWithContracts(q, contractId, name, s.signerEmail);
        } else {
            s.envelopeId = resend && q.NF_Envelope_Id__c.startsWith(SANDBOX_PREFIX)
                ? q.NF_Envelope_Id__c : SANDBOX_PREFIX + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).left(10).toUpperCase();
            NF_Trace.note('ESIGN', 'Sandbox e-signature', 'DocuSign is not connected; envelope ' + s.envelopeId);
        }
        NF_DocumentService.patchQuote(q.Id, new Map<String, Object>{
            'NF_Signature_Status__c' => NF_DocumentService.STATUS_SENT, 'NF_Envelope_Id__c' => s.envelopeId, 'NF_Signer_Name__c' => name.left(120)
        }, 'sent for signature (' + s.provider + ')');
        return s;
    }

    /**
     * The signer finished (or the page asks again): DocuSign / Salesforce Contracts must report the envelope
     * completed; the sandbox needs the typed name to match the signer.
     */
    public static NF_JourneyModels.AgreementState complete(String quoteId, String envelopeId, NF_JourneyModels.CustomerDetails signer,
                                                           String typedSignature, NF_JourneyModels.JourneyContext ctx) {
        Quote q = NF_DocumentService.loadQuote(quoteId, ctx);
        if (q.NF_Signature_Status__c == NF_DocumentService.STATUS_SIGNED) return NF_DocumentService.state(q, null);
        if (q.NF_Signature_Status__c != NF_DocumentService.STATUS_SENT || String.isBlank(envelopeId) || envelopeId != q.NF_Envelope_Id__c) {
            throw new NF_JourneyModels.JourneyException('This signing session has expired. Please start signing again.');
        }
        String signedVersionId;
        SignedPdfJob fileSignedPdf;
        if (envelopeId.startsWith(SANDBOX_PREFIX)) {
            String expected = (q.NF_Signer_Name__c ?? '').normalizeSpace().toLowerCase();
            if (String.isBlank(typedSignature) || typedSignature.normalizeSpace().toLowerCase() != expected) {
                throw new NF_JourneyModels.JourneyException('Type your full name exactly as shown to sign.');
            }
            signedVersionId = q.NF_Document_Id__c;
            NF_Trace.note('ESIGN', 'Sandbox e-signature', q.NF_Signer_Name__c + ' signed ' + envelopeId);
        } else if (envelopeId.startsWith(CONTRACTS_PREFIX)) {
            Id contractId = (Id) envelopeId.removeStart(CONTRACTS_PREFIX);
            String status = contractsEnvelopeStatus(contractId);
            if (status != 'Completed') return pending(q, status == 'Declined' ? 'The proposal was declined.'
                : 'Waiting for ' + q.NF_Signer_Name__c + ' to sign the proposal sent by email.');
            signedVersionId = latestContractPdf(contractId) ?? q.NF_Document_Id__c;
        } else {
            DocuSign ds = new DocuSign(settings());
            String status = ds.envelopeStatus(envelopeId);
            if (status != 'completed') return pending(q, status == 'declined' ? 'The agreement was declined.' : 'The agreement is not signed yet.');
            // Signed: the customer moves on now; the signed PDF is fetched and filed in the background.
            signedVersionId = q.NF_Document_Id__c;
            fileSignedPdf = new SignedPdfJob(q.Id, envelopeId, NF_DocumentService.title(q));
        }
        NF_DocumentService.patchQuote(q.Id, new Map<String, Object>{
            'NF_Signature_Status__c' => NF_DocumentService.STATUS_SIGNED, 'NF_Signed_Document_Id__c' => signedVersionId,
            'NF_Signed_At__c' => DateTime.now()
        }, 'signed');
        q.NF_Signature_Status__c = NF_DocumentService.STATUS_SIGNED;
        q.NF_Signed_Document_Id__c = signedVersionId;
        q.NF_Signed_At__c = DateTime.now();
        NF_JourneyModels.AgreementState signed = NF_DocumentService.state(q, null);
        if (fileSignedPdf != null) {
            // Last: a queued job counts as pending work, and no callout may follow it in this transaction.
            System.enqueueJob(fileSignedPdf);
            NF_Trace.note('ESIGN', 'Signed PDF queued', 'SignedPdfJob files the completed DocuSign document on the contract');
        }
        return signed;
    }

    /** Downloads the completed envelope and files it on the contract (and its document version) as the signed PDF. */
    public class SignedPdfJob implements Queueable, Database.AllowsCallouts {
        Id quoteId;
        String envelopeId;
        String title;
        public SignedPdfJob(Id quoteId, String envelopeId, String title) {
            this.quoteId = quoteId;
            this.envelopeId = envelopeId;
            this.title = title;
        }
        public void execute(QueueableContext ctx) {
            Blob signedPdf = new DocuSign(settings()).signedDocument(envelopeId);
            Id contractId = NF_DocumentService.contractOf(quoteId);
            Map<String, Object> cv = NF_RevCloudApi.post('/sobjects/ContentVersion', new Map<String, Object>{
                'Title' => title + ' (signed)', 'PathOnClient' => title + ' (signed).pdf',
                'VersionData' => EncodingUtil.base64Encode(signedPdf), 'FirstPublishLocationId' => contractId ?? quoteId
            }, 'Signed PDF from DocuSign → contract files');
            String signedVersionId = String.valueOf(cv.get('id'));
            Id versionId = contractId == null ? null : NF_DocumentService.latestVersionOf(contractId);
            if (versionId != null) {
                Map<String, Object> doc = NF_RevCloudApi.get('/sobjects/ContentVersion/' + signedVersionId + '?fields=ContentDocumentId', 'Signed PDF document');
                NF_DocumentService.fileOnVersion(versionId, String.valueOf(doc.get('ContentDocumentId')), signedVersionId, 'SignedDocument');
            }
            NF_DocumentService.patchQuote(quoteId, new Map<String, Object>{ 'NF_Signed_Document_Id__c' => signedVersionId }, 'signed PDF filed');
        }
    }

    // ── DocuSign access token, shared for its lifetime (Platform Cache) ──────

    private static final String TOKEN_KEY = 'nfDocuSignToken';

    private static String cachedToken() {
        try {
            return (String) Cache.Org.getPartition('local.NFJourney').get(TOKEN_KEY);
        } catch (Exception e) {
            return null;
        }
    }

    private static void cacheToken(String token, Integer expiresIn) {
        try {
            Cache.Org.getPartition('local.NFJourney').put(TOKEN_KEY, token, Math.max(300, expiresIn - 600));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'NF DocuSign token not cached: ' + e.getMessage());
        }
    }

    private static NF_JourneyModels.AgreementState pending(Quote q, String message) {
        NF_JourneyModels.AgreementState s = NF_DocumentService.state(q, null);
        s.message = message;
        return s;
    }

    // ── Salesforce Contracts e-signature (native) ────────────────────────────

    private static void sendWithContracts(Quote q, Id contractId, String name, String email) {
        // The documents the default DocuSign document selector offers for the contract (its current version).
        Map<String, Object> docs = NF_RevCloudApi.get('/connect/e-sign/documents?sourceObjectId=' + contractId, 'Salesforce Contracts · documents to sign');
        List<Object> documents = new List<Object>();
        Integer n = 1;
        for (Object o : docs.get('documents') instanceof List<Object> ? (List<Object>) docs.get('documents') : new List<Object>()) {
            Map<String, Object> d = (Map<String, Object>) o;
            documents.add(new Map<String, Object>{ 'name' => d.get('name'), 'sourceId' => d.get('sourceId'), 'fileExtension' => d.get('fileExtension'),
                'sourceType' => d.get('sourceType'), 'documentId' => String.valueOf(n++) });
        }
        if (documents.isEmpty()) throw new NF_JourneyModels.JourneyException('The proposal is not ready to send yet.');
        NF_RevCloudApi.post('/connect/e-sign/signature-requests/' + contractId + '/envelope/send', new Map<String, Object>{
            'vendor' => 'Docusign',
            'emailSettings' => new Map<String, Object>{
                'emailSubject' => ('Please sign: ' + NF_DocumentService.title(q)).left(100),
                'emailBody' => 'Hello ' + name + ', please review and sign the NovaFiber Business proposal for your sites.' },
            'recipients' => new Map<String, Object>{ 'signers' => new List<Object>{ new Map<String, Object>{
                // recipientId goes to DocuSign as is (Int or Guid); signerRole = the signer number in the template anchors
                'name' => name, 'email' => email, 'routingOrder' => 1, 'recipientId' => '1', 'signerRole' => 1, 'recipientType' => 'Contact' } } },
            'documents' => documents
        }, 'Salesforce Contracts · send proposal for e-signature (DocuSign)');
    }

    private static String contractsEnvelopeStatus(Id contractId) {
        try {
            NF_RevCloudApi.patch('/connect/e-sign/signature-requests/' + contractId + '/envelopes/status', new Map<String, Object>(),
                'Salesforce Contracts · sync envelope status from DocuSign', null);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'NF envelope status sync failed: ' + e.getMessage());
        }
        List<Map<String, Object>> rows = NF_RevCloudApi.query('SELECT Status FROM DocumentEnvelope WHERE ReferenceObjectId = \'' + contractId
            + '\' ORDER BY CreatedDate DESC LIMIT 1', 'DocumentEnvelope status');
        return rows.isEmpty() ? null : String.valueOf(rows[0].get('Status'));
    }

    private static String latestContractPdf(Id contractId) {
        List<Map<String, Object>> rows = NF_RevCloudApi.query('SELECT ContentDocument.LatestPublishedVersionId FROM ContractDocVerContentDoc '
            + 'WHERE ContractDocumentVersion.ContractId = \'' + contractId + '\' AND ContentDocument.FileExtension = \'pdf\' '
            + 'ORDER BY CreatedDate DESC LIMIT 1', 'Signed proposal PDF');
        if (rows.isEmpty()) return null;
        Map<String, Object> doc = (Map<String, Object>) rows[0].get('ContentDocument');
        return doc == null ? null : String.valueOf(doc.get('LatestPublishedVersionId'));
    }

    // ── DocuSign eSignature REST (JWT grant), household embedded signing ─────

    @TestVisible
    private class DocuSign {
        NF_DocuSign_Settings__c cfg;
        String accessToken;
        String baseUri;

        DocuSign(NF_DocuSign_Settings__c cfg) {
            this.cfg = cfg;
        }

        String authHost() {
            return String.isBlank(cfg.Auth_Host__c) ? 'account-d.docusign.com' : cfg.Auth_Host__c;
        }

        /** JWT grant: assertion signed RS256 by the Salesforce certificate whose public key is on the DocuSign app. */
        String token() {
            if (accessToken != null) return accessToken;
            accessToken = cachedToken();
            if (accessToken != null) return accessToken;
            Long now = DateTime.now().getTime() / 1000;
            String header = base64Url(Blob.valueOf('{"alg":"RS256","typ":"JWT"}'));
            String claims = base64Url(Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'iss' => cfg.Integration_Key__c, 'sub' => cfg.User_Id__c, 'aud' => authHost(),
                'iat' => now, 'exp' => now + 3600, 'scope' => 'signature impersonation' })));
            Blob signature = Crypto.signWithCertificate('RSA-SHA256', Blob.valueOf(header + '.' + claims),
                String.isBlank(cfg.Certificate_Name__c) ? 'NF_DocuSign_JWT' : cfg.Certificate_Name__c);
            HttpRequest req = new HttpRequest();
            req.setEndpoint('https://' + authHost() + '/oauth/token');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            req.setBody('grant_type=' + EncodingUtil.urlEncode('urn:ietf:params:oauth:grant-type:jwt-bearer', 'UTF-8')
                + '&assertion=' + header + '.' + claims + '.' + base64Url(signature));
            Map<String, Object> res = send(req, 'DocuSign · JWT grant access token', null);
            accessToken = String.valueOf(res.get('access_token'));
            cacheToken(accessToken, res.get('expires_in') == null ? 3600 : Integer.valueOf(res.get('expires_in')));
            return accessToken;
        }

        String base() {
            if (baseUri != null) return baseUri;
            if (String.isNotBlank(cfg.Base_Uri__c)) {
                baseUri = cfg.Base_Uri__c.removeEnd('/');
                return baseUri;
            }
            HttpRequest req = new HttpRequest();
            req.setEndpoint('https://' + authHost() + '/oauth/userinfo');
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + token());
            for (Object a : (List<Object>) send(req, 'DocuSign · userinfo (account base URI)', null).get('accounts')) {
                Map<String, Object> acc = (Map<String, Object>) a;
                if (String.valueOf(acc.get('account_id')) == cfg.Account_Id__c) baseUri = String.valueOf(acc.get('base_uri')).removeEnd('/');
            }
            return baseUri;
        }

        String accountPath() {
            return base() + '/restapi/v2.1/accounts/' + cfg.Account_Id__c;
        }

        String createEnvelope(String title, Blob pdf, String name, String email, Id clientUserId) {
            Map<String, Object> tabs = new Map<String, Object>{
                'signHereTabs' => new List<Object>{ new Map<String, Object>{ 'anchorString' => '[[SIGN_CUSTOMER]]', 'anchorUnits' => 'pixels',
                    'anchorXOffset' => '0', 'anchorYOffset' => '-4' } },
                'dateSignedTabs' => new List<Object>{ new Map<String, Object>{ 'anchorString' => '[[DATE_CUSTOMER]]', 'anchorUnits' => 'pixels',
                    'anchorXOffset' => '0', 'anchorYOffset' => '0', 'anchorIgnoreIfNotPresent' => 'true' } }
            };
            HttpRequest req = request('POST', accountPath() + '/envelopes');
            req.setBody(JSON.serialize(new Map<String, Object>{
                'emailSubject' => ('Please sign: ' + title).left(100),
                'documents' => new List<Object>{ new Map<String, Object>{
                    'documentBase64' => EncodingUtil.base64Encode(pdf), 'name' => title, 'fileExtension' => 'pdf', 'documentId' => '1' } },
                'recipients' => new Map<String, Object>{ 'signers' => new List<Object>{ new Map<String, Object>{
                    'email' => email, 'name' => name, 'recipientId' => '1', 'routingOrder' => '1',
                    'clientUserId' => String.valueOf(clientUserId), 'tabs' => tabs } } },
                'status' => 'sent'
            }));
            return String.valueOf(send(req, 'DocuSign · create envelope (embedded signer)', '{ PDF ' + pdf.size() + ' bytes, signer ' + name + ' }').get('envelopeId'));
        }

        String recipientView(String envelopeId, String name, String email, Id clientUserId, String returnUrl, String pageOrigin) {
            Map<String, Object> body = new Map<String, Object>{
                'returnUrl' => returnUrl, 'authenticationMethod' => 'none', 'email' => email, 'userName' => name,
                'clientUserId' => String.valueOf(clientUserId)
            };
            if (String.isNotBlank(pageOrigin)) {
                // Embedded in the journey page (iframe): allow this site and DocuSign's own app frame.
                body.put('frameAncestors', new List<String>{ pageOrigin, 'https://apps-d.docusign.com' });
                body.put('messageOrigins', new List<String>{ 'https://apps-d.docusign.com' });
            }
            HttpRequest req = request('POST', accountPath() + '/envelopes/' + envelopeId + '/views/recipient');
            req.setBody(JSON.serialize(body));
            return String.valueOf(send(req, 'DocuSign · embedded signing view', JSON.serialize(body)).get('url'));
        }

        String envelopeStatus(String envelopeId) {
            return String.valueOf(send(request('GET', accountPath() + '/envelopes/' + envelopeId), 'DocuSign · envelope status', null).get('status'));
        }

        Blob signedDocument(String envelopeId) {
            HttpRequest req = request('GET', accountPath() + '/envelopes/' + envelopeId + '/documents/combined');
            req.setHeader('Accept', 'application/pdf');
            NF_Trace.Entry t = NF_Trace.start('ESIGN', 'GET envelopes/' + envelopeId + '/documents/combined', 'DocuSign · signed PDF');
            HttpResponse res = new Http().send(req);
            NF_Trace.end(t, res.getStatusCode() == 200 ? 'OK' : 'ERROR', 'HTTP ' + res.getStatusCode());
            if (res.getStatusCode() != 200) throw new NF_JourneyModels.JourneyException('We could not fetch the signed document. Please try again.');
            return res.getBodyAsBlob();
        }

        HttpRequest request(String method, String url) {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(url);
            req.setMethod(method);
            req.setTimeout(60000);
            req.setHeader('Authorization', 'Bearer ' + token());
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            return req;
        }

        Map<String, Object> send(HttpRequest req, String label, String requestForTrace) {
            NF_Trace.Entry t = NF_Trace.start('ESIGN', req.getMethod() + ' ' + req.getEndpoint().substringAfter('.com').substringAfter('.net'), label);
            if (requestForTrace != null) NF_Trace.request(t, requestForTrace);
            HttpResponse res;
            try {
                res = new Http().send(req);
            } catch (CalloutException e) {
                NF_Trace.end(t, 'ERROR', e.getMessage());
                throw new NF_JourneyModels.JourneyException('DocuSign is not reachable right now. Please try again.');
            }
            Boolean ok = res.getStatusCode() >= 200 && res.getStatusCode() < 300;
            String body = res.getBody() ?? '';
            NF_Trace.end(t, ok ? 'OK' : 'ERROR', 'HTTP ' + res.getStatusCode() + '\n'
                + body.replaceAll('"access_token"\\s*:\\s*"[^"]*"', '"access_token":"••••••"').left(4000));
            if (!ok) {
                System.debug(LoggingLevel.ERROR, 'NF DocuSign ' + label + ' failed: HTTP ' + res.getStatusCode() + ' ' + body);
                throw new NF_JourneyModels.JourneyException('DocuSign could not complete that step (' + res.getStatusCode() + '). Please try again.');
            }
            return String.isBlank(body) ? new Map<String, Object>() : (Map<String, Object>) JSON.deserializeUntyped(body);
        }
    }

    private static String base64Url(Blob b) {
        return EncodingUtil.base64Encode(b).replace('+', '-').replace('/', '_').replace('=', '');
    }
}
