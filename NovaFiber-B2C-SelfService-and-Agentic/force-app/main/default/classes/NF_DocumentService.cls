/**
 * NF_DocumentService
 * Customer documents from native Salesforce document templates, before the order is placed.
 *
 *   Household agreement (Salesforce Contracts + Data Mappers)
 *     Contract from the quote (standard action createContract; source quote, signer contact) →
 *     contract document version from template "NovaFiber Home Service Agreement" (createContractDocumentVersion),
 *     whose tokens come from the Data Mappers NFHomeAgreementExtract → NFHomeAgreementTransform.
 *   Business proposal (Revenue Cloud quote document + context definition)
 *     Document Generation of template "NovaFiber Business Proposal" with Context Service input = the quote
 *     (context NF_ProposalContext, QuoteEntitiesMapping) → the PDF becomes the contract document version of a
 *     Contract created from the quote, ready for Salesforce Contracts e-signature.
 *
 * Generation is asynchronous (DocumentGenerationProcess); the page polls poll() until the PDF exists. Everything
 * runs through REST as the integration user, so site visitors are served too. Signature tracking lives on the
 * quote (NF_Signature_Status__c, NF_Document_Id__c, …); signing is NF_ESignService.
 */
public without sharing class NF_DocumentService {

    public static final String KIND_AGREEMENT = 'agreement';
    public static final String KIND_PROPOSAL = 'proposal';
    @TestVisible static final String AGREEMENT_TEMPLATE = 'NovaFiber Home Service Agreement';
    @TestVisible static final String PROPOSAL_TEMPLATE = 'NovaFiber Business Proposal';
    private static final Integer HOME_TERM_MONTHS = 24;      // price lock
    private static final Integer BUSINESS_TERM_MONTHS = 36;
    private static final Map<String, String> ALLOW_DUPLICATES = new Map<String, String>{ 'Sforce-Duplicate-Rule-Header' => 'allowSave=true' };

    public static final String STATUS_GENERATING = 'Generating';
    public static final String STATUS_GENERATED = 'Generated';
    public static final String STATUS_SENT = 'Sent';
    public static final String STATUS_SIGNED = 'Signed';

    // ── Public API ───────────────────────────────────────────────────────────

    /** Starts the agreement or proposal for this signer; poll() until the PDF is ready. */
    public static NF_JourneyModels.AgreementState generate(String quoteId, NF_JourneyModels.CustomerDetails signer,
                                                           NF_JourneyModels.JourneyContext ctx) {
        Quote q = loadQuote(quoteId, ctx);
        if (q.NF_Signature_Status__c == STATUS_SIGNED) return state(q, null);
        validateSigner(signer);
        Id contactId = ensureContact(q.QuoteAccountId, signer);
        String jobId;
        Map<String, Object> quoteFields = new Map<String, Object>{
            'NF_Signature_Status__c' => STATUS_GENERATING, 'NF_Document_Id__c' => null, 'NF_Envelope_Id__c' => null,
            'NF_Signer_Name__c' => fullName(signer).left(120)
        };
        if (isBusiness(q)) {
            // The proposal reads these through the context definition, so they are on the quote before rendering.
            quoteFields.putAll(siteSummary(q, ctx));
            patchQuote(q.Id, quoteFields, 'proposal · signer and sites for the template');
            jobId = startProposal(q);
        } else {
            patchQuote(q.Id, quoteFields, 'agreement · generating');
            Id contractId = ensureContract(q, contactId);
            jobId = startAgreement(contractId);
        }
        q.NF_Signature_Status__c = STATUS_GENERATING;
        q.NF_Signer_Name__c = fullName(signer);
        return state(q, jobId);
    }

    /** Current state; with a job id, checks that generation and records its PDF when it is done. */
    public static NF_JourneyModels.AgreementState poll(String quoteId, String jobId, NF_JourneyModels.JourneyContext ctx) {
        Quote q = loadQuote(quoteId, ctx);
        if (String.isBlank(jobId) || q.NF_Signature_Status__c != STATUS_GENERATING) return state(q, null);

        Map<String, Object> job = NF_RevCloudApi.get('/sobjects/DocumentGenerationProcess/' + jobId
            + '?fields=Status,ResponseText,ReferenceObject,SourceObjectId', 'Document Generation · job status');
        if (!belongsTo(job, q)) throw new NF_JourneyModels.JourneyException('We could not find that document.');
        String status = String.valueOf(job.get('Status'));
        if (status == 'Failure') {
            patchQuote(q.Id, new Map<String, Object>{ 'NF_Signature_Status__c' => null }, 'document · generation failed');
            System.debug(LoggingLevel.ERROR, 'NF document generation failed for ' + q.QuoteNumber + ': ' + job.get('ResponseText'));
            q.NF_Signature_Status__c = null;
            NF_JourneyModels.AgreementState failed = state(q, null);
            failed.status = 'Failed';
            failed.message = 'We could not prepare the document. Please try again.';
            return failed;
        }
        if (status != 'Success') return state(q, jobId);

        // ResponseText: "<docx version id>,<pdf version id>" (contracts) or "<pdf version id>" (quote document)
        List<String> versions = String.valueOf(job.get('ResponseText')).deleteWhitespace().split(',');
        String pdfVersionId = versions[versions.size() - 1];
        if (isBusiness(q)) attachProposalToContract(q, pdfVersionId);
        patchQuote(q.Id, new Map<String, Object>{ 'NF_Signature_Status__c' => STATUS_GENERATED, 'NF_Document_Id__c' => pdfVersionId },
            (isBusiness(q) ? 'proposal' : 'agreement') + ' · generated');
        q.NF_Document_Id__c = pdfVersionId;
        q.NF_Signature_Status__c = STATUS_GENERATED;
        return state(q, null);
    }

    // ── Household: Salesforce Contracts + Data Mappers ───────────────────────

    /** The quote's contract (standard createContract from the quote), with its source quote and signer. */
    public static Id ensureContract(Quote q, Id contactId) {
        Id existing = contractOf(q.Id);
        Boolean business = isBusiness(q);
        Map<String, Object> fields = new Map<String, Object>{
            'SourceQuoteId' => q.Id, 'CustomerSignedId' => contactId, 'ContractTerm' => business ? BUSINESS_TERM_MONTHS : HOME_TERM_MONTHS,
            'Description' => business ? 'NovaFiber Business Services Agreement: 36-month term per site from activation (proposal ' + q.QuoteNumber + ').'
                : 'NovaFiber Home Service Agreement: no annual contract, 24-month price lock (quote ' + q.QuoteNumber + ').'
        };
        if (existing != null) {
            NF_RevCloudApi.patch('/sobjects/Contract/' + existing, fields, 'Contract · signer and source quote', null);
            return existing;
        }
        List<Object> res = NF_RevCloudApi.postList('/actions/standard/createContract', new Map<String, Object>{
            'inputs' => new List<Object>{ new Map<String, Object>{ 'sourceId' => q.Id } }
        }, 'Revenue Cloud · create Contract from Quote ' + q.QuoteNumber);
        Map<String, Object> out = res.isEmpty() ? new Map<String, Object>() : (Map<String, Object>) res[0];
        Map<String, Object> values = out.get('outputValues') instanceof Map<String, Object> ? (Map<String, Object>) out.get('outputValues') : null;
        if (out.get('isSuccess') != true || values?.get('contractId') == null) {
            throw new NF_JourneyModels.JourneyException('We could not prepare your agreement. Please try again.');
        }
        Id contractId = (Id) String.valueOf(values.get('contractId'));
        NF_RevCloudApi.patch('/sobjects/Contract/' + contractId, fields, 'Contract · signer and source quote', null);
        NF_Trace.rec('INSERT', 'Contract', contractId, 'createContract from quote');
        return contractId;
    }

    /** Contract document version from the agreement template (Data Mappers fill the tokens); returns the job id. */
    private static String startAgreement(Id contractId) {
        String templateId = templateId(AGREEMENT_TEMPLATE);
        Id versionId = latestVersion(contractId);
        Map<String, Object> rep;
        if (versionId != null) {
            rep = NF_RevCloudApi.patch('/connect/clm/contract-document-version/' + versionId, new Map<String, Object>{ 'templateId' => templateId },
                'Salesforce Contracts · regenerate document version (Data Mapper template)', null);
        } else {
            List<Object> res = NF_RevCloudApi.postList('/actions/standard/createContractDocumentVersion', new Map<String, Object>{
                'inputs' => new List<Object>{ new Map<String, Object>{ 'contractId' => contractId, 'templateId' => templateId } }
            }, 'Salesforce Contracts · contract document version from "' + AGREEMENT_TEMPLATE + '"');
            Map<String, Object> out = res.isEmpty() ? new Map<String, Object>() : (Map<String, Object>) res[0];
            Map<String, Object> values = out.get('outputValues') instanceof Map<String, Object> ? (Map<String, Object>) out.get('outputValues') : new Map<String, Object>();
            rep = values.get('documentGenerateRepresentationResponse') instanceof Map<String, Object>
                ? (Map<String, Object>) values.get('documentGenerateRepresentationResponse') : new Map<String, Object>();
        }
        if (rep.get('jobId') == null) throw new NF_JourneyModels.JourneyException('We could not prepare your agreement. Please try again.');
        return String.valueOf(rep.get('jobId'));
    }

    // ── Business: quote document from the context definition ─────────────────

    private static String startProposal(Quote q) {
        Map<String, Object> res = NF_RevCloudApi.post('/sobjects/DocumentGenerationProcess', new Map<String, Object>{
            'Type' => 'GenerateAndConvert', 'DocGenApiVersionType' => 'Advanced', 'ReferenceObject' => q.Id,
            'DocumentInputType' => 'DocumentTemplate', 'DocumentTemplateId' => templateId(PROPOSAL_TEMPLATE),
            'DocGenAdditionalInputType' => 'ContextService', 'DocGenAdditionalInput' => q.Id,
            'RequestText' => JSON.serialize(new Map<String, Object>{ 'title' => title(q), 'keepIntermediate' => false })
        }, 'Document Generation · "' + PROPOSAL_TEMPLATE + '" (Context Service: NF_ProposalContext)');
        if (res.get('id') == null) throw new NF_JourneyModels.JourneyException('We could not prepare the proposal. Please try again.');
        return String.valueOf(res.get('id'));
    }

    /** The proposal PDF becomes the document version of a Contract created from the quote (for e-signature). */
    private static void attachProposalToContract(Quote q, String pdfVersionId) {
        Id contractId = ensureContract(q, contactOf(q));
        Map<String, Object> cv = NF_RevCloudApi.get('/sobjects/ContentVersion/' + pdfVersionId + '?fields=ContentDocumentId', 'Proposal PDF');
        Id versionId = latestVersion(contractId);
        if (versionId != null) {
            // A contract has one draft version: a regenerated proposal replaces the version's contract document.
            for (Map<String, Object> link : NF_RevCloudApi.query('SELECT Id FROM ContractDocVerContentDoc WHERE ContractDocumentVersionId = \''
                    + versionId + '\' AND DocumentType = \'ContractDocument\'', 'Current proposal document')) {
                NF_RevCloudApi.del('/sobjects/ContractDocVerContentDoc/' + link.get('Id'), 'Salesforce Contracts · retire previous proposal');
            }
            fileOnVersion(versionId, String.valueOf(cv.get('ContentDocumentId')), pdfVersionId, 'ContractDocument');
        } else {
            NF_RevCloudApi.postList('/actions/standard/createContractDocumentVersion', new Map<String, Object>{
                'inputs' => new List<Object>{ new Map<String, Object>{ 'contractId' => contractId, 'pdfDocumentId' => cv.get('ContentDocumentId') } }
            }, 'Salesforce Contracts · contract document version from the proposal PDF');
            versionId = latestVersion(contractId);
        }
        // Check in: Salesforce Contracts e-signature only sends active contract documents.
        NF_RevCloudApi.postList('/actions/standard/checkInContractDocumentVersion', new Map<String, Object>{
            'inputs' => new List<Object>{ new Map<String, Object>{ 'contractDocumentVersionId' => versionId } }
        }, 'Salesforce Contracts · check in the proposal version');
    }

    /** Files a PDF on a contract document version (DocumentType ContractDocument or SignedDocument). */
    public static void fileOnVersion(Id versionId, String contentDocumentId, String contentVersionId, String documentType) {
        NF_RevCloudApi.post('/sobjects/ContractDocVerContentDoc', new Map<String, Object>{
            'Name' => (String.valueOf(versionId) + contentVersionId).left(80), 'ContractDocumentVersionId' => versionId,
            'ContentDocumentId' => contentDocumentId, 'ContentVersion' => contentVersionId,
            'DocumentSourceType' => 'Content', 'DocumentType' => documentType
        }, 'Salesforce Contracts · ' + documentType + ' on the contract document version');
    }

    public static Id latestVersionOf(Id contractId) {
        return latestVersion(contractId);
    }

    /** Site count, states and preparer, stamped on the quote for the proposal. */
    private static Map<String, Object> siteSummary(Quote q, NF_JourneyModels.JourneyContext ctx) {
        Set<String> states = new Set<String>();
        Integer sites = 0;
        for (QuoteLineItemRecipient r : [SELECT ServiceState FROM QuoteLineItemRecipient WHERE QuoteId = :q.Id]) {
            sites++;
            if (String.isNotBlank(r.ServiceState)) states.add(r.ServiceState);
        }
        List<String> sorted = new List<String>(states);
        sorted.sort();
        String last = sorted.isEmpty() ? '' : sorted.remove(sorted.size() - 1);
        String stateList = sorted.isEmpty() ? last : String.join(sorted, ', ') + ' and ' + last;
        return new Map<String, Object>{
            'NF_Site_Count__c' => sites, 'NF_State_List__c' => stateList,
            'NF_Prepared_By__c' => ctx.isAgent == true ? UserInfo.getName() + ', NovaFiber Business' : 'NovaFiber Business Sales'
        };
    }

    // ── Quote, access and state ──────────────────────────────────────────────

    public static Quote loadQuote(String quoteId, NF_JourneyModels.JourneyContext ctx) {
        List<Quote> qs = String.isBlank(quoteId) ? new List<Quote>() : [
            SELECT Id, Name, QuoteNumber, Status, QuoteAccountId, QuoteAccount.Name, NF_Channel__c,
                   NF_Signature_Status__c, NF_Document_Id__c, NF_Signed_Document_Id__c, NF_Envelope_Id__c, NF_Signed_At__c, NF_Signer_Name__c
            FROM Quote WHERE Id = :quoteId LIMIT 1
        ];
        if (qs.isEmpty() || qs[0].NF_Channel__c == null || qs[0].Name == NF_QuoteService.WORKSPACE_NAME) {
            throw new NF_JourneyModels.JourneyException('We could not find your quote. Please start again.');
        }
        Quote q = qs[0];
        Boolean isProspect = (q.QuoteAccount?.Name ?? '').startsWith(NF_QuoteService.PROSPECT_PREFIX);
        if (ctx.isAgent != true && !isProspect) {
            throw new NF_JourneyModels.JourneyException('This quote cannot be signed online. Please contact NovaFiber.');
        }
        return q;
    }

    public static Boolean isBusiness(Quote q) {
        return (q.Name ?? '').startsWith(NF_MultiSiteService.QUOTE_PREFIX);
    }

    public static String title(Quote q) {
        return isBusiness(q) ? 'NovaFiber Business Proposal ' + q.QuoteNumber : 'NovaFiber Home Service Agreement ' + q.QuoteNumber;
    }

    public static NF_JourneyModels.AgreementState state(Quote q, String jobId) {
        NF_JourneyModels.AgreementState s = new NF_JourneyModels.AgreementState();
        s.quoteId = q.Id;
        s.kind = isBusiness(q) ? KIND_PROPOSAL : KIND_AGREEMENT;
        s.title = title(q);
        s.status = q.NF_Signature_Status__c;
        s.processId = jobId;
        s.envelopeId = q.NF_Envelope_Id__c;
        s.signerName = q.NF_Signer_Name__c;
        s.provider = NF_ESignService.provider(q);
        if (q.NF_Signed_At__c != null) s.signedAt = q.NF_Signed_At__c.format('MMM d, yyyy h:mm a z');
        if (q.NF_Signature_Status__c == STATUS_SIGNED && String.isNotBlank(q.NF_Signed_Document_Id__c)) {
            s.signedDocumentUrl = viewLink(q.NF_Signed_Document_Id__c, s.title + ' (signed)');
        } else if (String.isNotBlank(q.NF_Document_Id__c) && q.NF_Signature_Status__c != STATUS_GENERATING) {
            s.documentUrl = viewLink(q.NF_Document_Id__c, s.title);
        }
        return s;
    }

    public static void patchQuote(Id quoteId, Map<String, Object> fields, String label) {
        NF_RevCloudApi.patch('/sobjects/Quote/' + quoteId, fields, 'Quote · ' + label, null);
        NF_Trace.rec('UPDATE', 'Quote', quoteId, label);
    }

    /** The contract created from this quote (createContract links it as Quote.ContractId), if any. */
    public static Id contractOf(Id quoteId) {
        List<Quote> qs = [SELECT ContractId FROM Quote WHERE Id = :quoteId LIMIT 1];
        if (!qs.isEmpty() && qs[0].ContractId != null) return qs[0].ContractId;
        List<Map<String, Object>> rows = NF_RevCloudApi.query(
            'SELECT Id FROM Contract WHERE SourceQuoteId = \'' + quoteId + '\' ORDER BY CreatedDate DESC LIMIT 1', 'Contract of the quote');
        return rows.isEmpty() ? null : (Id) String.valueOf(rows[0].get('Id'));
    }

    private static Id contactOf(Quote q) {
        List<Contact> cs = [SELECT Id FROM Contact WHERE AccountId = :q.QuoteAccountId ORDER BY CreatedDate DESC LIMIT 1];
        return cs.isEmpty() ? null : cs[0].Id;
    }

    private static Id latestVersion(Id contractId) {
        List<Map<String, Object>> rows = NF_RevCloudApi.query('SELECT Id FROM ContractDocumentVersion WHERE ContractId = \'' + contractId
            + '\' ORDER BY VersionNumber DESC LIMIT 1', 'Contract document version');
        return rows.isEmpty() ? null : (Id) String.valueOf(rows[0].get('Id'));
    }

    private static String templateId(String name) {
        List<Map<String, Object>> rows = NF_RevCloudApi.query('SELECT Id FROM DocumentTemplate WHERE Name = \'' + String.escapeSingleQuotes(name)
            + '\' AND IsActive = true ORDER BY VersionNumber DESC LIMIT 1', 'Document template "' + name + '"');
        if (rows.isEmpty()) throw new NF_JourneyModels.JourneyException('Document templates are not set up yet.');
        return String.valueOf(rows[0].get('Id'));
    }

    /** A job belongs to the quote (proposal) or to a document version of the quote's contract (agreement). */
    private static Boolean belongsTo(Map<String, Object> job, Quote q) {
        if (String.valueOf(job.get('ReferenceObject')) == String.valueOf(q.Id)) return true;
        Object source = job.get('SourceObjectId');
        if (source == null) return false;
        List<Map<String, Object>> rows = NF_RevCloudApi.query('SELECT Contract.SourceQuoteId FROM ContractDocumentVersion WHERE Id = \''
            + String.escapeSingleQuotes(String.valueOf(source)) + '\'', 'Document version → quote');
        Map<String, Object> contract = rows.isEmpty() ? null : (Map<String, Object>) rows[0].get('Contract');
        return contract != null && String.valueOf(contract.get('SourceQuoteId')) == String.valueOf(q.Id);
    }

    /** Signer as a contact on the customer's account (the agreement's account holder, the contract's signer). */
    private static Id ensureContact(Id accountId, NF_JourneyModels.CustomerDetails c) {
        String email = c.email.trim().toLowerCase();
        List<Contact> existing = [SELECT Id FROM Contact WHERE AccountId = :accountId AND Email = :email LIMIT 1];
        Map<String, Object> fields = new Map<String, Object>{
            'FirstName' => c.firstName.trim(), 'LastName' => c.lastName.trim(), 'Email' => email, 'Phone' => c.phone
        };
        if (!existing.isEmpty()) {
            NF_RevCloudApi.patch('/sobjects/Contact/' + existing[0].Id, fields, 'Signer contact', ALLOW_DUPLICATES);
            return existing[0].Id;
        }
        fields.put('AccountId', accountId);
        Map<String, Object> res = NF_RevCloudApi.post('/sobjects/Contact', fields, 'Signer contact', ALLOW_DUPLICATES);
        if (res.get('id') == null) throw new NF_JourneyModels.JourneyException('We could not save your contact details. Please try again.');
        NF_Trace.rec('INSERT', 'Contact', (Id) String.valueOf(res.get('id')), 'signer');
        return (Id) String.valueOf(res.get('id'));
    }

    // ── View links ───────────────────────────────────────────────────────────

    /** A short-lived public view link (ContentDistribution) so visitors can open the PDF. */
    private static String viewLink(String contentVersionId, String name) {
        try {
            Map<String, Object> res = NF_RevCloudApi.post('/sobjects/ContentDistribution', new Map<String, Object>{
                'Name' => name.left(100), 'ContentVersionId' => contentVersionId,
                'PreferencesAllowViewInBrowser' => true, 'PreferencesAllowOriginalDownload' => true,
                'PreferencesAllowPDFDownload' => true, 'PreferencesLinkLatestVersion' => false,
                'PreferencesNotifyOnVisit' => false, 'PreferencesPasswordRequired' => false,
                'PreferencesExpires' => true, 'ExpiryDate' => DateTime.now().addHours(4)
            }, 'View link · ' + name);
            Map<String, Object> d = NF_RevCloudApi.get('/sobjects/ContentDistribution/' + res.get('id') + '?fields=DistributionPublicUrl',
                'View link URL');
            return String.valueOf(d.get('DistributionPublicUrl'));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'NF view link failed: ' + e.getMessage());
            return null;
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    public static String fullName(NF_JourneyModels.CustomerDetails c) {
        return c == null ? '' : ((c.firstName ?? '').trim() + ' ' + (c.lastName ?? '').trim()).trim();
    }

    private static void validateSigner(NF_JourneyModels.CustomerDetails c) {
        if (c == null || String.isBlank(c.firstName) || String.isBlank(c.lastName) || String.isBlank(c.email)) {
            throw new NF_JourneyModels.JourneyException('Please enter the signer\'s name and email first.');
        }
    }
}
