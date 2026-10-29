/**
 * NF_JourneyModels
 * Data contracts shared by the NovaFiber guided selling LWCs and the NF_* services.
 * Every field is @AuraEnabled so the same shapes serialise to both channels
 * (Experience Cloud self-service and the internal agent console).
 */
public with sharing class NF_JourneyModels {

    public static final String CHANNEL_SELF_SERVICE = 'Self-Service';
    public static final String CHANNEL_AGENT = 'Agent-Assisted';
    public static final String CHANNEL_AI_AGENT = 'AI Agent';

    // ── Journey context ──────────────────────────────────────────────────────

    public class JourneyContext {
        @AuraEnabled public String channel;
        @AuraEnabled public Boolean isAgent;
        @AuraEnabled public Boolean canDiscount;
        @AuraEnabled public Decimal maxDiscountPercent;
        @AuraEnabled public Boolean canOverrideServiceability;
        @AuraEnabled public Boolean canSelectAccount;
        @AuraEnabled public String userName;
        @AuraEnabled public String currencyIsoCode;
        @AuraEnabled public Boolean isGuest;
        @AuraEnabled public String journeyMode;         // org default: Cached | Realtime (NF_Journey_Setting__mdt)
        @AuraEnabled public Boolean canFlushCache;      // agents
        @AuraEnabled public Boolean inspectorAllowed;   // agents always; guests when NF_Journey_Setting__mdt allows ?debug=1
    }

    // ── Serviceability ───────────────────────────────────────────────────────

    public class Address {
        @AuraEnabled public String street;
        @AuraEnabled public String unit;
        @AuraEnabled public String city;
        @AuraEnabled public String state;
        @AuraEnabled public String postalCode;
        @AuraEnabled public String country;

        public String singleLine() {
            List<String> parts = new List<String>();
            parts.add(String.isBlank(unit) ? street : street + ', ' + unit);
            parts.add(city);
            parts.add(state + ' ' + postalCode);
            return String.join(parts, ', ');
        }
    }

    public class Technology {
        @AuraEnabled public String technology;
        @AuraEnabled public Integer maxDownloadMbps;
        @AuraEnabled public Integer maxUploadMbps;
        @AuraEnabled public String installType;
        @AuraEnabled public Integer leadTimeDays;
    }

    public class ServiceabilityResult {
        @AuraEnabled public String serviceabilityId;
        @AuraEnabled public String status;            // SERVICEABLE | PARTIAL | NOT_SERVICEABLE
        @AuraEnabled public String message;
        @AuraEnabled public Boolean tvAvailable;
        @AuraEnabled public List<Technology> technologies;
        @AuraEnabled public Address address;
        @AuraEnabled public Boolean overridden;       // agent forced serviceability
    }

    // ── Offers ───────────────────────────────────────────────────────────────

    public class OfferCategory {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public List<Offer> offers;
    }

    public class Offer {
        @AuraEnabled public String productId;
        @AuraEnabled public String productCode;
        @AuraEnabled public String name;
        @AuraEnabled public String tagline;
        @AuraEnabled public List<String> highlights;
        @AuraEnabled public String categoryKey;
        @AuraEnabled public Decimal price;
        @AuraEnabled public String chargeType;        // Monthly | One-Time
        @AuraEnabled public Boolean isBundle;
        @AuraEnabled public Boolean isFeatured;
        @AuraEnabled public Integer downloadMbps;
        @AuraEnabled public Integer uploadMbps;
        @AuraEnabled public String technology;
        @AuraEnabled public List<OptionGroup> groups;
        // Revenue Cloud references from Discovery, used to build configurator nodes
        @AuraEnabled public String priceBookEntryId;
        @AuraEnabled public String productSellingModelId;
        @AuraEnabled public String sellingModelType;    // Evergreen | TermDefined | OneTime
    }

    public class OptionGroup {
        @AuraEnabled public String groupId;
        @AuraEnabled public String name;
        @AuraEnabled public Integer minOptions;
        @AuraEnabled public Integer maxOptions;
        @AuraEnabled public List<Option> options;
    }

    public class Option {
        @AuraEnabled public String componentId;       // ProductRelatedComponent Id
        @AuraEnabled public String productId;
        @AuraEnabled public String name;
        @AuraEnabled public String tagline;
        @AuraEnabled public Decimal price;
        @AuraEnabled public String chargeType;
        @AuraEnabled public Boolean isRequired;
        @AuraEnabled public Boolean isDefault;
        @AuraEnabled public Boolean isQuantityEditable;
        @AuraEnabled public Integer defaultQuantity;
        @AuraEnabled public Integer minQuantity;
        @AuraEnabled public Integer maxQuantity;
        @AuraEnabled public String priceBookEntryId;
        @AuraEnabled public String productSellingModelId;
        @AuraEnabled public String sellingModelType;
        @AuraEnabled public String relationshipTypeId; // ProductRelationshipType of the component
    }

    // ── Cart / Quote ─────────────────────────────────────────────────────────

    /**
     * The cart is a draft Quote configured through the Revenue Cloud configurator.
     * quoteId is null until the first sync creates the draft (prospect account + service location).
     */
    public class CartRequest {
        @AuraEnabled public String quoteId;           // draft quote behind the cart
        @AuraEnabled public String contextId;         // configurator session from the last sync (reused while alive)
        @AuraEnabled public List<String> lineIds;     // that session's line node ids
        @AuraEnabled public String accountId;         // agent only: existing customer account
        @AuraEnabled public ServiceabilityResult serviceability;
        @AuraEnabled public List<CartItem> items;
    }

    public class CartItem {
        @AuraEnabled public String key;               // client cart key: configurator messages map back to it
        @AuraEnabled public String productId;
        @AuraEnabled public Integer quantity;
        @AuraEnabled public Decimal discountPercent;  // agent only
        @AuraEnabled public List<SelectedOption> options;
    }

    public class SelectedOption {
        @AuraEnabled public String componentId;
        @AuraEnabled public Integer quantity;
    }

    public class QuoteSummary {
        @AuraEnabled public String quoteId;
        @AuraEnabled public String quoteNumber;
        @AuraEnabled public String status;
        @AuraEnabled public String accountId;
        @AuraEnabled public List<QuoteLine> lines;
        @AuraEnabled public Decimal monthlyTotal;
        @AuraEnabled public Decimal oneTimeTotal;
        @AuraEnabled public Decimal monthlySavings;
        @AuraEnabled public String pricingNote;
        @AuraEnabled public Boolean isSaved;            // false: live configurator session; true: lines saved on the quote
        @AuraEnabled public String contextId;           // configurator session (Context Service) that produced this
        @AuraEnabled public List<String> sessionLineIds; // the line nodes now in that session (replaced on the next change)
        @AuraEnabled public Boolean fromCache;          // priced cart served from the journey cache
        @AuraEnabled public List<CartMessage> messages; // configurator rule / bundle validation messages
        @AuraEnabled public Boolean hasErrors;
        @AuraEnabled public List<RuleAdjustment> ruleAdjustments; // options the CML rules added or removed
        @AuraEnabled public List<HiddenOption> hiddenOptions;     // options the CML rules hide or disable
    }

    /** What the configuration rules (CML) changed in a cart item: its options as Revenue Cloud left them. */
    public class RuleAdjustment {
        @AuraEnabled public String itemKey;
        @AuraEnabled public String productName;
        @AuraEnabled public List<SelectedOption> options;
        @AuraEnabled public List<String> added;
        @AuraEnabled public List<String> removed;
    }

    /** An option a configuration rule hides or disables for a cart item (CML exclude / hide / disable). */
    public class HiddenOption {
        @AuraEnabled public String itemKey;
        @AuraEnabled public String componentId;
        @AuraEnabled public String treatment;          // hide | disable
    }

    /** A Revenue Cloud configurator message, attached to the cart item it concerns (itemKey null = whole cart). */
    public class CartMessage {
        @AuraEnabled public String itemKey;
        @AuraEnabled public String productName;
        @AuraEnabled public String severity;           // error | warning | info
        @AuraEnabled public String category;           // e.g. bundlevalidation, rule
        @AuraEnabled public String message;
    }

    public class QuoteLine {
        @AuraEnabled public String itemKey;
        @AuraEnabled public String lineId;
        @AuraEnabled public String parentLineId;
        @AuraEnabled public String productId;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal listPrice;
        @AuraEnabled public Decimal discountPercent;
        @AuraEnabled public Decimal netTotal;
        @AuraEnabled public String chargeType;
    }

    // ── Checkout / Order ─────────────────────────────────────────────────────

    public class CustomerDetails {
        @AuraEnabled public String firstName;
        @AuraEnabled public String lastName;
        @AuraEnabled public String email;
        @AuraEnabled public String phone;
        @AuraEnabled public Date preferredInstallDate;
        @AuraEnabled public Boolean acceptedTerms;
        /** My NovaFiber password chosen at checkout: hashed into NF_Portal_User__c and cleared, never stored or logged. */
        @AuraEnabled public String portalPassword;
    }

    public class OrderResult {
        @AuraEnabled public String orderId;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String status;
        @AuraEnabled public String accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String quoteId;
        @AuraEnabled public Decimal monthlyTotal;
        @AuraEnabled public Decimal oneTimeTotal;
        @AuraEnabled public Date installDate;
        @AuraEnabled public String pendingRequestKey;
        @AuraEnabled public String fulfillmentStatus;      // customer milestone after DRO submission
        @AuraEnabled public Boolean submittedToFulfillment;
        @AuraEnabled public String portalUsername;         // login for tracking the order on the portal
        @AuraEnabled public String bookingToken;           // lets this visitor book the installation (NF_SchedulingService)
        @AuraEnabled public String contractId;             // Contract from the signed agreement / proposal
        @AuraEnabled public String contractNumber;
    }

    /** What discarding a journey removed (its draft quote, and the prospect account when nothing else uses it). */
    public class DiscardResult {
        @AuraEnabled public Boolean discarded;
        @AuraEnabled public List<String> deleted;
    }

    public class AccountMatch {
        @AuraEnabled public String accountId;
        @AuraEnabled public String name;
        @AuraEnabled public String billingAddress;
        @AuraEnabled public String phone;
    }

    // ── Multi-site quoting (agents) ──────────────────────────────────────────

    /** A service location from the uploaded sites file. */
    public class SiteInput {
        @AuraEnabled public String key;               // client key, echoed back
        @AuraEnabled public String name;              // e.g. "HQ", "Austin store"
        @AuraEnabled public Address address;
    }

    public class SiteResult {
        @AuraEnabled public String key;
        @AuraEnabled public String name;
        @AuraEnabled public ServiceabilityResult serviceability;
        @AuraEnabled public List<OfferCategory> offers;
        @AuraEnabled public String error;             // the site couldn't be checked (bad address, service down)
    }

    /** Products to price in each state (browse-time location prices; nothing is saved). */
    public class StatePriceRequest {
        @AuraEnabled public List<String> states;
        @AuraEnabled public List<String> productIds;
    }

    public class StatePrices {
        @AuraEnabled public String state;
        @AuraEnabled public Map<String, Decimal> prices;   // productId → list price in this state
    }

    public class SiteCart {
        @AuraEnabled public String key;
        @AuraEnabled public String name;
        @AuraEnabled public ServiceabilityResult serviceability;
        @AuraEnabled public List<CartItem> items;
    }

    public class MultiSiteRequest {
        @AuraEnabled public String accountId;         // existing customer account, or
        @AuraEnabled public String companyName;       // a new business account with this name
        @AuraEnabled public List<SiteCart> sites;
    }

    public class SiteSummary {
        @AuraEnabled public String key;
        @AuraEnabled public String name;
        @AuraEnabled public String state;
        @AuraEnabled public Decimal monthlyTotal;
        @AuraEnabled public Decimal oneTimeTotal;
        @AuraEnabled public List<QuoteLine> lines;
        @AuraEnabled public List<CartMessage> messages;
        @AuraEnabled public Boolean hasErrors;
        @AuraEnabled public List<RuleAdjustment> ruleAdjustments;
        @AuraEnabled public List<HiddenOption> hiddenOptions;
    }

    public class MultiSiteQuote {
        @AuraEnabled public String quoteId;
        @AuraEnabled public String quoteNumber;
        @AuraEnabled public String accountId;
        @AuraEnabled public List<SiteSummary> sites;
        @AuraEnabled public Decimal monthlyTotal;
        @AuraEnabled public Decimal oneTimeTotal;
    }

    // ── Installation booking (NF_SchedulingService) ──────────────────────────

    /** A service location of an order that needs an installation appointment. */
    public class InstallSite {
        @AuraEnabled public String siteKey;                // 'main' for a household, QuoteLineItemRecipient Id for a business site
        @AuraEnabled public String name;
        @AuraEnabled public String address;
        @AuraEnabled public String state;
        @AuraEnabled public InstallAppointment appointment;
    }

    /** Arrival windows over the next two working weeks for one site, in the territory's time zone. */
    public class InstallCalendar {
        @AuraEnabled public String siteKey;
        @AuraEnabled public String siteName;
        @AuraEnabled public String address;
        @AuraEnabled public String territoryName;
        @AuraEnabled public String timeZone;
        @AuraEnabled public String timeZoneLabel;
        @AuraEnabled public String workType;
        @AuraEnabled public Decimal durationHours;
        @AuraEnabled public Integer crews;
        @AuraEnabled public List<SlotDay> days;
        @AuraEnabled public InstallAppointment appointment;
    }

    public class SlotDay {
        @AuraEnabled public String dateKey;                // yyyy-MM-dd (territory time zone)
        @AuraEnabled public String weekday;                // Mon
        @AuraEnabled public String label;                  // Oct 27
        @AuraEnabled public Integer available;             // free crew-windows that day
        @AuraEnabled public List<Slot> slots;
    }

    public class Slot {
        @AuraEnabled public String slotKey;                // arrival window start, UTC ISO-8601
        @AuraEnabled public String label;                  // 8–10 AM
        @AuraEnabled public Integer available;             // free crews
    }

    public class InstallAppointment {
        @AuraEnabled public String siteKey;
        @AuraEnabled public String siteName;
        @AuraEnabled public String workOrderId;
        @AuraEnabled public String workOrderNumber;
        @AuraEnabled public String appointmentId;
        @AuraEnabled public String appointmentNumber;
        @AuraEnabled public String status;
        @AuraEnabled public String crewName;
        @AuraEnabled public String territoryName;
        @AuraEnabled public String slotKey;
        @AuraEnabled public String dateLabel;              // Tuesday, Oct 27
        @AuraEnabled public String windowLabel;            // 8–10 AM ET
    }

    // ── Agreements, proposals and e-signature (NF_DocumentService, NF_ESignService) ──

    /** Where the quote's agreement (household) or proposal (business) is: generated, out for signature, signed. */
    public class AgreementState {
        @AuraEnabled public String quoteId;
        @AuraEnabled public String kind;                   // agreement | proposal
        @AuraEnabled public String title;
        @AuraEnabled public String status;                 // Generating | Generated | Sent | Finalizing | Signed | Failed
        @AuraEnabled public String processId;              // DocumentGenerationProcess being polled
        @AuraEnabled public String documentUrl;            // short-lived view link of the current PDF
        @AuraEnabled public String signedDocumentUrl;
        @AuraEnabled public String provider;               // DocuSign | Sandbox
        @AuraEnabled public String envelopeId;
        @AuraEnabled public String signerName;
        @AuraEnabled public String signedAt;
        @AuraEnabled public String message;
    }

    /** Starting signature: DocuSign embedded signing URL, or the sandbox signing pad. */
    public class SigningSession {
        @AuraEnabled public String provider;               // DocuSign | Sandbox
        @AuraEnabled public String envelopeId;
        @AuraEnabled public String signingUrl;
        @AuraEnabled public String signerName;
        @AuraEnabled public String signerEmail;
    }

    // ── Transport ────────────────────────────────────────────────────────────

    /** What every NF_JourneyController call returns: the payload, or a safe error, plus the inspector trace. */
    public class Envelope {
        @AuraEnabled public String dataJson;
        @AuraEnabled public String error;
        @AuraEnabled public List<NF_Trace.Entry> trace;
        @AuraEnabled public Map<String, Integer> limits;
        @AuraEnabled public Integer serverMs;
    }

    // ── Errors ───────────────────────────────────────────────────────────────

    /** Business error with a message that is safe to show to customers. */
    public class JourneyException extends Exception {}
}
