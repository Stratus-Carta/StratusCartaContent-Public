@IsTest
private class NF_JourneyTest {

    // ── Test doubles ─────────────────────────────────────────────────────────

    private class ServiceabilityMock implements HttpCalloutMock {
        Integer status;
        String body;
        ServiceabilityMock(Integer status, String body) { this.status = status; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            System.assert(req.getEndpoint().startsWith(NF_ServiceabilityService.ENDPOINT), req.getEndpoint());
            HttpResponse r = new HttpResponse();
            r.setStatusCode(status);
            r.setBody(body);
            return r;
        }
    }

    private class AnyCalloutMock implements HttpCalloutMock {
        Integer status;
        String body;
        AnyCalloutMock(Integer status, String body) { this.status = status; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(status);
            r.setBody(body);
            return r;
        }
    }

    private static final String FIBER_BODY = '{"serviceabilityId":"SVC-1","status":"SERVICEABLE","message":"ok",'
        + '"tvAvailable":true,"technologies":[{"technology":"Fiber","maxDownloadMbps":1000,"maxUploadMbps":1000,'
        + '"installType":"Existing Drop","leadTimeDays":3}]}';
    private static final String NONE_BODY = '{"serviceabilityId":"SVC-2","status":"NOT_SERVICEABLE","message":"no",'
        + '"tvAvailable":false,"technologies":[]}';
    private static final String MESH_RULE = 'Mesh extenders work best with professional installation.';

    /**
     * Stands in for the Revenue Cloud REST APIs NF_RevCloudApi calls, over the test catalog:
     *  - Product Discovery (/connect/cpq/products, /bulk). Qualification mirrors the ProductQualification
     *    rules: the address technology (Account.NF_AccessTechnology) must be one of the product's
     *    technologies (or "Any") and the product speed must not exceed Account.NF_MaxDownloadMbps.
     *  - sObject REST (prospect account), Place Sales Transaction (draft header, save), and the
     *    configurator (sessions keyed by quote; a rule emits MESH_RULE when the mesh option is chosen).
     */
    private class FakeRevenueCloud implements NF_RevCloudApi.Responder {
        Boolean failConfigure = false;
        Boolean failPlace = false;
        Boolean failOrder = false;
        Integer droSubmissions = 0;
        Boolean ruleError = false;
        Map<String, List<Map<String, Object>>> sessions = new Map<String, List<Map<String, Object>>>();

        public String respond(String method, String path, String requestBody) {
            if (method == 'DELETE') {
                if (path.startsWith('/composite/sobjects')) {
                    Database.delete(path.substringAfter('ids=').split(','));
                } else {
                    Database.delete((Id) path.substringAfterLast('/'));
                }
                return '';
            }
            Map<String, Object> req = (Map<String, Object>) JSON.deserializeUntyped(requestBody);
            if (method == 'PATCH') return updateRecord(path, req);
            if (path == '/sobjects/Account') return createAccount(req);
            if (path == '/sobjects/Contact') return createContact(req);
            if (path == '/actions/standard/createOrdersFromQuote') return createOrder(req);
            if (path == '/actions/standard/submitOrder') {
                droSubmissions++;
                return '[{"actionName":"submitOrder","isSuccess":true,"outputValues":{"submitStatus":"SUBMITTED","requestId":"req-test"}}]';
            }
            if (path == '/connect/rev/sales-transaction/actions/place') return place(req);
            if (path == '/connect/cpq/configurator/actions/configure') return configure(req);
            return discover(path, req);
        }

        // Product Discovery
        private String discover(String path, Map<String, Object> req) {
            Boolean qualify = req.get('enableQualification') == true;
            String tech;
            Decimal maxMbps;
            if (req.get('additionalContextData') != null) {
                for (Object o : (List<Object>) req.get('additionalContextData')) {
                    Map<String, Object> data = (Map<String, Object>) ((Map<String, Object>) o).get('nodeData');
                    tech = (String) data.get('NF_AccessTechnology');
                    maxMbps = Decimal.valueOf(String.valueOf(data.get('NF_MaxDownloadMbps')));
                }
            }
            List<Object> out = new List<Object>();
            if (path == '/connect/cpq/products/bulk') {
                Set<Id> ids = new Set<Id>();
                for (Object o : (List<Object>) req.get('productData')) ids.add((Id) ((Map<String, Object>) o).get('productId'));
                for (Product2 p : products(ids)) {
                    Map<String, Object> m = product(p, null, qualify, tech, maxMbps);
                    m.put('productComponentGroups', groups(p.Id));
                    out.add(m);
                }
            } else {
                // Every category of the product, in any catalog (the service keeps the ones of its own catalog).
                Map<Id, List<Id>> categoriesOf = new Map<Id, List<Id>>();
                for (ProductCategoryProduct pcp : [SELECT ProductId, ProductCategoryId FROM ProductCategoryProduct]) {
                    if (!categoriesOf.containsKey(pcp.ProductId)) categoriesOf.put(pcp.ProductId, new List<Id>());
                    categoriesOf.get(pcp.ProductId).add(pcp.ProductCategoryId);
                }
                for (Product2 p : products(categoriesOf.keySet())) out.add(product(p, categoriesOf.get(p.Id), qualify, tech, maxMbps));
            }
            return JSON.serialize(new Map<String, Object>{
                'apiStatus' => new Map<String, Object>{ 'statusCode' => 'FetchedDetailsSuccessfully', 'messages' => new List<Object>() },
                'result' => out
            });
        }

        private List<Product2> products(Set<Id> ids) {
            return [
                SELECT Id, Name, ProductCode, Type, NF_AccessTechnology__c, NF_DownloadMbps__c, NF_UploadMbps__c,
                       NF_Tagline__c, NF_Highlights__c, NF_IsFeatured__c, NF_DisplayOrder__c,
                       (SELECT Id, UnitPrice, ProductSellingModelId, ProductSellingModel.SellingModelType
                        FROM PricebookEntries WHERE IsActive = true)
                FROM Product2 WHERE Id IN :ids
            ];
        }

        private Map<String, Object> product(Product2 p, List<Id> categoryIds, Boolean qualify, String tech, Decimal maxMbps) {
            Boolean ok = true;
            if (qualify) {
                List<String> techs = String.isBlank(p.NF_AccessTechnology__c) ? new List<String>() : p.NF_AccessTechnology__c.split(';');
                ok = techs.contains('Any') || (techs.contains(tech)
                    && (p.NF_DownloadMbps__c == null || p.NF_DownloadMbps__c <= maxMbps));
            }
            Map<String, Object> qc = new Map<String, Object>{ 'isQualified' => ok };
            if (!ok) qc.put('reason', 'Product is not qualified because one or more field(s) do not match');
            List<Object> prices = new List<Object>();
            for (PricebookEntry e : p.PricebookEntries) {
                prices.add(new Map<String, Object>{ 'isDefault' => true, 'price' => e.UnitPrice, 'priceBookEntryId' => e.Id,
                    'pricingModel' => new Map<String, Object>{ 'id' => e.ProductSellingModelId,
                        'pricingModelType' => e.ProductSellingModel.SellingModelType } });
            }
            return new Map<String, Object>{
                'id' => p.Id, 'name' => p.Name, 'productCode' => p.ProductCode, 'productType' => p.Type,
                'categories' => categories(categoryIds),
                'prices' => prices,
                'qualificationContext' => qc,
                'additionalFields' => new Map<String, Object>{
                    'NF_Tagline__c' => p.NF_Tagline__c, 'NF_Highlights__c' => p.NF_Highlights__c,
                    'NF_DownloadMbps__c' => p.NF_DownloadMbps__c, 'NF_UploadMbps__c' => p.NF_UploadMbps__c,
                    'NF_IsFeatured__c' => p.NF_IsFeatured__c, 'NF_DisplayOrder__c' => p.NF_DisplayOrder__c }
            };
        }

        private List<Object> categories(List<Id> categoryIds) {
            List<Object> out = new List<Object>();
            if (categoryIds != null) for (Id c : categoryIds) out.add(new Map<String, Object>{ 'id' => c });
            return out;
        }

        private List<Object> groups(Id parentId) {
            List<Object> out = new List<Object>();
            for (ProductComponentGroup g : [
                SELECT Id, Name, MinBundleComponents, MaxBundleComponents,
                       (SELECT Id, ChildProductId, IsComponentRequired, IsDefaultComponent, IsQuantityEditable,
                               Quantity, MinQuantity, MaxQuantity, ProductRelationshipTypeId
                        FROM ProductComponentGroups ORDER BY Sequence ASC NULLS LAST)
                FROM ProductComponentGroup WHERE ParentProductId = :parentId ORDER BY Sequence ASC NULLS LAST
            ]) {
                Set<Id> childIds = new Set<Id>();
                for (ProductRelatedComponent c : g.ProductComponentGroups) childIds.add(c.ChildProductId);
                Map<Id, Product2> children = new Map<Id, Product2>(products(childIds));
                List<Object> comps = new List<Object>();
                for (ProductRelatedComponent c : g.ProductComponentGroups) {
                    Map<String, Object> comp = product(children.get(c.ChildProductId), null, false, null, null);
                    comp.put('productRelatedComponent', new Map<String, Object>{
                        'id' => c.Id, 'isComponentRequired' => c.IsComponentRequired, 'isDefaultComponent' => c.IsDefaultComponent,
                        'isQuantityEditable' => c.IsQuantityEditable, 'quantity' => c.Quantity,
                        'minQuantity' => c.MinQuantity, 'maxQuantity' => c.MaxQuantity,
                        'productRelationshipTypeId' => c.ProductRelationshipTypeId });
                    comps.add(comp);
                }
                out.add(new Map<String, Object>{ 'id' => g.Id, 'name' => g.Name,
                    'minBundleComponents' => g.MinBundleComponents, 'maxBundleComponents' => g.MaxBundleComponents,
                    'components' => comps });
            }
            return out;
        }

        // sObject REST
        private String updateRecord(String path, Map<String, Object> req) {
            Id recordId = (Id) path.substringAfterLast('/');
            SObject so = recordId.getSObjectType().newSObject(recordId);
            for (String field : req.keySet()) {
                // Order activation needs order items the fake orders don't have; DRO submission is faked above.
                if (field == 'Status' && recordId.getSObjectType() == Order.SObjectType) continue;
                Object v = req.get(field);
                Schema.DisplayType t = recordId.getSObjectType().getDescribe().fields.getMap().get(field).getDescribe().getType();
                so.put(field, v != null && t == Schema.DisplayType.DATE ? Date.valueOf((String) v) : v);
            }
            update so;
            return '';
        }

        private String createContact(Map<String, Object> req) {
            Contact c = new Contact(AccountId = (Id) req.get('AccountId'), FirstName = (String) req.get('FirstName'),
                LastName = (String) req.get('LastName'), Email = (String) req.get('Email'), Phone = (String) req.get('Phone'));
            Database.insert(c, NF_QuoteService.allowDuplicates());
            return JSON.serialize(new Map<String, Object>{ 'id' => c.Id, 'success' => true });
        }

        // Revenue Cloud createOrderFromQuote
        private String createOrder(Map<String, Object> req) {
            Map<String, Object> input = (Map<String, Object>) ((List<Object>) req.get('inputs'))[0];
            System.assertEquals('CreateSingleOrder', input.get('orderCreationMethod'));
            Id quoteId = (Id) input.get('quoteId');
            if (failOrder) {
                return '[{"actionName":"createOrdersFromQuote","isSuccess":false,"outputValues":null,'
                    + '"errors":[{"statusCode":"REQUIRED_FIELD_MISSING","message":"Required fields are missing: [ServiceDate]"}]}]';
            }
            Quote q = [SELECT QuoteAccountId, StartDate FROM Quote WHERE Id = :quoteId];
            // The org trigger copies Quote.StartDate onto the lines; the order needs those dates.
            System.assertNotEquals(null, q.StartDate, 'the quote must carry a StartDate');
            Order o = new Order(AccountId = q.QuoteAccountId, QuoteId = quoteId, EffectiveDate = Date.today(), Status = 'Draft',
                Pricebook2Id = Test.getStandardPricebookId());
            insert o;
            return JSON.serialize(new List<Object>{ new Map<String, Object>{ 'isSuccess' => true,
                'outputValues' => new Map<String, Object>{ 'orderIds' => new List<Object>{ o.Id } } } });
        }

        private String createAccount(Map<String, Object> req) {
            Account a = new Account(Name = (String) req.get('Name'), BillingPostalCode = (String) req.get('BillingPostalCode'));
            Database.insert(a, NF_QuoteService.allowDuplicates());   // the REST call sends Sforce-Duplicate-Rule-Header
            return JSON.serialize(new Map<String, Object>{ 'id' => a.Id, 'success' => true });
        }

        // Place Sales Transaction
        private String place(Map<String, Object> req) {
            Map<String, Object> graph = (Map<String, Object>) req.get('graph');
            List<Object> records = (List<Object>) graph.get('records');
            if (failPlace) {
                return JSON.serialize(new Map<String, Object>{ 'isSuccess' => false,
                    'errorResponse' => new List<Object>{ new Map<String, Object>{ 'message' => 'Pricing failed' } } });
            }
            if (graph.get('graphId') == 'nfQuoteLines') {
                Id quoteId;
                List<QuoteLineItem> qlis = new List<QuoteLineItem>();
                for (Object o : records) {
                    Map<String, Object> r = (Map<String, Object>) ((Map<String, Object>) o).get('record');
                    Map<String, Object> attrs = (Map<String, Object>) r.get('attributes');
                    if (attrs.get('type') == 'Quote') quoteId = (Id) attrs.get('id');
                    if (attrs.get('type') != 'QuoteLineItem') continue;
                    PricebookEntry e = [SELECT UnitPrice FROM PricebookEntry WHERE Id = :(Id) r.get('PricebookEntryId')];
                    qlis.add(new QuoteLineItem(QuoteId = (Id) r.get('QuoteId'), Product2Id = (Id) r.get('Product2Id'),
                        PricebookEntryId = (Id) r.get('PricebookEntryId'), Quantity = Decimal.valueOf(String.valueOf(r.get('Quantity'))),
                        UnitPrice = e.UnitPrice, Discount = r.get('Discount') == null ? null : Decimal.valueOf(String.valueOf(r.get('Discount'))),
                        QuoteLineItemRecipientId = (Id) r.get('QuoteLineItemRecipientId'),
                        ServiceDate = r.get('ServiceDate') == null ? null : Date.valueOf((String) r.get('ServiceDate'))));
                }
                insert qlis;
                return placed(quoteId);
            }
            if (graph.get('graphId') == 'nfQuoteHeader') {
                Map<String, Object> q = (Map<String, Object>) ((Map<String, Object>) records[0]).get('record');
                Quote quote = new Quote(Name = (String) q.get('Name'), Pricebook2Id = (Id) q.get('Pricebook2Id'),
                    QuoteAccountId = (Id) q.get('QuoteAccountId'), NF_Channel__c = (String) q.get('NF_Channel__c'),
                    StartDate = q.get('StartDate') == null ? null : Date.valueOf((String) q.get('StartDate')),
                    NF_ServiceabilityRef__c = (String) q.get('NF_ServiceabilityRef__c'));
                insert quote;
                Map<String, Object> r = (Map<String, Object>) ((Map<String, Object>) records[1]).get('record');
                insert new QuoteLineItemRecipient(QuoteId = quote.Id, Name = (String) r.get('Name'), RecipientType = 'Location',
                    ServiceCity = (String) r.get('ServiceCity'), ServicePostalCode = (String) r.get('ServicePostalCode'));
                return placed(quote.Id);
            }
            if (new Set<Object>{ 'nfLocationRecipients', 'nfMsHeader', 'nfMsLines' }.contains(graph.get('graphId'))) {
                return placeRecords(records);
            }
            throw new NF_RevCloudApi.RevCloudException('unexpected graph ' + graph.get('graphId'));
        }

        /** Multi-site graphs: Quote POST/PATCH, recipients, line groups and lines, with @{ref.id} references. */
        private String placeRecords(List<Object> records) {
            Map<String, Id> refs = new Map<String, Id>();
            List<QuoteLineItem> lines = new List<QuoteLineItem>();
            List<String> lineRefs = new List<String>();
            Id quoteId;
            for (Object o : records) {
                Map<String, Object> entry = (Map<String, Object>) o;
                Map<String, Object> r = (Map<String, Object>) entry.get('record');
                Map<String, Object> attrs = (Map<String, Object>) r.get('attributes');
                String type = (String) attrs.get('type');
                SObject created;
                if (type == 'Quote') {
                    if (attrs.get('method') == 'PATCH') {
                        quoteId = (Id) attrs.get('id');
                        continue;
                    }
                    created = new Quote(Name = (String) r.get('Name'), Pricebook2Id = (Id) r.get('Pricebook2Id'),
                        QuoteAccountId = (Id) r.get('QuoteAccountId'), NF_Channel__c = (String) r.get('NF_Channel__c'),
                        StartDate = r.get('StartDate') == null ? null : Date.valueOf((String) r.get('StartDate')));
                } else if (type == 'QuoteLineItemRecipient') {
                    created = new QuoteLineItemRecipient(QuoteId = ref(refs, r.get('QuoteId')), Name = (String) r.get('Name'),
                        RecipientType = 'Location', ServiceState = (String) r.get('ServiceState'),
                        ServiceCity = (String) r.get('ServiceCity'), ServicePostalCode = (String) r.get('ServicePostalCode'));
                } else if (type == 'QuoteLineGroup') {
                    created = new QuoteLineGroup(QuoteId = ref(refs, r.get('QuoteId')), Name = (String) r.get('Name'));
                } else if (type == 'QuoteLineItem') {
                    Id recipientId = (Id) r.get('QuoteLineItemRecipientId');
                    created = new QuoteLineItem(QuoteId = (Id) r.get('QuoteId'), Product2Id = (Id) r.get('Product2Id'),
                        PricebookEntryId = (Id) r.get('PricebookEntryId'), Quantity = Decimal.valueOf(String.valueOf(r.get('Quantity'))),
                        UnitPrice = price((Id) r.get('PricebookEntryId'), recipientId),
                        QuoteLineItemRecipientId = recipientId, QuoteLineGroupId = (Id) r.get('QuoteLineGroupId'));
                } else {
                    continue;   // bundle relationships aren't needed by the fake
                }
                if (type == 'QuoteLineItem') {
                    // like Place Sales Transaction: lines are inserted together (one trigger / flow batch)
                    lineRefs.add((String) entry.get('referenceId'));
                    lines.add((QuoteLineItem) created);
                    continue;
                }
                insert created;
                refs.put((String) entry.get('referenceId'), created.Id);
                if (type == 'Quote') quoteId = created.Id;
            }
            insert lines;
            for (Integer i = 0; i < lines.size(); i++) refs.put(lineRefs[i], lines[i].Id);
            return placed(quoteId);
        }

        private Id ref(Map<String, Id> refs, Object value) {
            String v = String.valueOf(value);
            return v.startsWith('@{') ? refs.get(v.substringBetween('@{', '.id}')) : (Id) v;
        }

        /** List price as the LocationBasedPrice step sets it: the recipient's state row in ItemLocationPrice__c, else the price book. */
        private Decimal price(Id pbeId, Id recipientId) {
            PricebookEntry e = [SELECT UnitPrice, Product2Id FROM PricebookEntry WHERE Id = :pbeId];
            if (recipientId == null) return e.UnitPrice;
            String state = [SELECT ServiceState FROM QuoteLineItemRecipient WHERE Id = :recipientId].ServiceState;
            List<ItemLocationPrice__c> rows = [SELECT Unit_Price__c FROM ItemLocationPrice__c
                WHERE Product__c = :e.Product2Id AND LocationState__c = :state LIMIT 1];
            return rows.isEmpty() ? e.UnitPrice : rows[0].Unit_Price__c;
        }

        private String placed(Id quoteId) {
            return JSON.serialize(new Map<String, Object>{ 'isSuccess' => true, 'salesTransactionId' => quoteId,
                'errorResponse' => new List<Object>() });
        }

        // Configurator
        private String configure(Map<String, Object> req) {
            Id quoteId = (Id) req.get('transactionId');
            String contextId = 'ctx-' + quoteId;
            if (req.get('transactionContextId') == null && req.get('addedNodes') == null) {
                List<Object> existing = new List<Object>();
                for (QuoteLineItem li : [SELECT Id FROM QuoteLineItem WHERE QuoteId = :quoteId]) {
                    existing.add(new Map<String, Object>{ 'id' => li.Id });
                }
                if (!sessions.containsKey(contextId)) sessions.put(contextId, new List<Map<String, Object>>());
                return session(contextId, existing, new Map<String, Object>());
            }
            if (failConfigure || (req.get('transactionContextId') != null && !sessions.containsKey((String) req.get('transactionContextId')))) {
                return JSON.serialize(new Map<String, Object>{ 'success' => false,
                    'errors' => new List<Object>{ new Map<String, Object>{ 'code' => 'CONTEXT_MUTATION_FAILED', 'message' => 'node not found' } } });
            }
            Map<String, Map<String, Object>> lines = new Map<String, Map<String, Object>>();
            Map<String, Object> rels = new Map<String, Object>();
            for (Object o : (List<Object>) req.get('addedNodes')) {
                Map<String, Object> obj = (Map<String, Object>) ((Map<String, Object>) o).get('addedObject');
                if (obj.get('businessObjectType') == 'QuoteLineItem') lines.put((String) obj.get('id'), obj);
                else rels.put((String) obj.get('AssociatedItem'), obj);
            }
            Set<Id> pbeIds = new Set<Id>();
            for (Map<String, Object> n : lines.values()) pbeIds.add((Id) n.get('PricebookEntry'));
            Map<Id, PricebookEntry> pbes = new Map<Id, PricebookEntry>([
                SELECT Id, UnitPrice, Product2.Name, Product2.ProductCode, ProductSellingModel.SellingModelType
                FROM PricebookEntry WHERE Id IN :pbeIds
            ]);
            List<Object> items = new List<Object>();
            List<Map<String, Object>> stored = new List<Map<String, Object>>();
            Map<String, Object> messages = new Map<String, Object>();
            for (String id : lines.keySet()) {
                Map<String, Object> n = lines.get(id);
                PricebookEntry e = pbes.get((Id) n.get('PricebookEntry'));
                Decimal qty = Decimal.valueOf(String.valueOf(n.get('Quantity')));
                Decimal disc = n.get('Discount') == null ? 0 : Decimal.valueOf(String.valueOf(n.get('Discount')));
                Map<String, Object> li = new Map<String, Object>(n);
                Decimal unit = price(e.Id, (Id) n.get('SalesTransactionRecipient'));
                li.put('ProductName', e.Product2.Name);
                li.put('ListPrice', unit);
                li.put('NetUnitPrice', unit * (1 - disc / 100));
                li.put('NetTotalPrice', unit * qty * (1 - disc / 100));
                li.put('SellingModelType', e.ProductSellingModel.SellingModelType);
                if (disc > 0) li.put('Discount', disc);
                if (rels.containsKey(id)) li.put('SalesTrxnItemRelationship', new List<Object>{ rels.get(id) });
                items.add(li);
                stored.add(li);
                if (e.Product2.ProductCode == 'T-MESH') {
                    String main = (String) ((Map<String, Object>) rels.get(id)).get('MainItem');
                    messages.put(main, new List<Object>{ new Map<String, Object>{ 'category' => 'rule', 'messageType' => 'warning',
                        'message' => MESH_RULE, 'relatedRecordId' => main } });
                }
            }
            if (ruleError) {
                messages.put(String.valueOf(quoteId), new List<Object>{ new Map<String, Object>{ 'category' => 'rule',
                    'messageType' => 'Error', 'message' => 'Blocked by a configuration rule.' } });
            }
            sessions.put(contextId, stored);
            return session(contextId, items, messages);
        }

        private String session(String contextId, List<Object> items, Map<String, Object> messages) {
            return JSON.serialize(new Map<String, Object>{
                'success' => true, 'transactionContextId' => contextId, 'messages' => messages,
                'transactionContext' => new Map<String, Object>{ 'SalesTransaction' => new List<Object>{
                    new Map<String, Object>{ 'SalesTransactionItem' => items } } }
            });
        }
    }

    private static FakeRevenueCloud fake;
    static {
        fake = new FakeRevenueCloud();
        NF_RevCloudApi.responder = fake;
    }

    /** Business error surfaced through NF_JourneyModels.Envelope.error. */
    private class ApiErrorException extends Exception {}

    // Typed wrappers over the envelope-returning controller (debug on, like the inspector).
    private static List<NF_Trace.Entry> lastTrace;

    private static Object unwrap(NF_JourneyModels.Envelope env, Type t) {
        lastTrace = env.trace;
        if (env.error != null) throw new ApiErrorException(env.error);
        return JSON.deserialize(env.dataJson, t);
    }
    private static NF_JourneyModels.ServiceabilityResult apiCheck(String addressJson) {
        return (NF_JourneyModels.ServiceabilityResult) unwrap(
            NF_JourneyController.checkServiceability(addressJson, true, null), NF_JourneyModels.ServiceabilityResult.class);
    }
    private static NF_JourneyModels.ServiceabilityResult apiOverride(String svcJson) {
        return (NF_JourneyModels.ServiceabilityResult) unwrap(
            NF_JourneyController.overrideServiceability(svcJson, true), NF_JourneyModels.ServiceabilityResult.class);
    }
    private static List<NF_JourneyModels.OfferCategory> apiOffers(String svcJson) {
        return (List<NF_JourneyModels.OfferCategory>) unwrap(
            NF_JourneyController.getOffers(svcJson, true, null), List<NF_JourneyModels.OfferCategory>.class);
    }
    private static NF_JourneyModels.QuoteSummary apiSync(NF_JourneyModels.CartRequest cart) {
        return apiSync(cart, null);
    }
    private static NF_JourneyModels.QuoteSummary apiSync(NF_JourneyModels.CartRequest cart, String mode) {
        return (NF_JourneyModels.QuoteSummary) unwrap(
            NF_JourneyController.syncCart(JSON.serialize(cart), true, mode), NF_JourneyModels.QuoteSummary.class);
    }
    private static NF_JourneyModels.QuoteSummary apiPrice(NF_JourneyModels.CartRequest cart) {
        return (NF_JourneyModels.QuoteSummary) unwrap(
            NF_JourneyController.priceCart(JSON.serialize(cart), true, null), NF_JourneyModels.QuoteSummary.class);
    }
    private static NF_JourneyModels.DiscardResult apiDiscard(String quoteId) {
        return (NF_JourneyModels.DiscardResult) unwrap(
            NF_JourneyController.discardJourney(quoteId, true), NF_JourneyModels.DiscardResult.class);
    }
    /** Orders need the signed agreement / proposal (NF_DocumentService + NF_ESignService, tested in NF_DocumentTest). */
    private static void markSigned(Id quoteId) {
        if (quoteId != null) update new Quote(Id = quoteId, NF_Signature_Status__c = NF_DocumentService.STATUS_SIGNED);
    }
    private static NF_JourneyModels.OrderResult apiSubmit(String quoteId, String customerJson) {
        markSigned(quoteId);
        return (NF_JourneyModels.OrderResult) unwrap(
            NF_JourneyController.submitOrder(quoteId, customerJson, true), NF_JourneyModels.OrderResult.class);
    }
    private static List<NF_JourneyModels.AccountMatch> apiSearch(String term) {
        return (List<NF_JourneyModels.AccountMatch>) unwrap(
            NF_JourneyController.searchAccounts(term, true), List<NF_JourneyModels.AccountMatch>.class);
    }
    private static NF_JourneyWorker.RequestResult apiPoll(String key) {
        return (NF_JourneyWorker.RequestResult) unwrap(
            NF_JourneyController.getRequestResult(key, true), NF_JourneyWorker.RequestResult.class);
    }
    private static Boolean traceHas(String kind) {
        if (lastTrace == null) return false;
        for (NF_Trace.Entry e : lastTrace) if (e.kind == kind) return true;
        return false;
    }

    // ── Data ─────────────────────────────────────────────────────────────────

    @TestSetup
    static void setup() {
        ProductSellingModel monthly = new ProductSellingModel(Name = 'NF Test Monthly', SellingModelType = 'Evergreen',
            Status = 'Active', PricingTerm = 1, PricingTermUnit = 'Months');
        ProductSellingModel oneTime = new ProductSellingModel(Name = 'NF Test One-Time', SellingModelType = 'OneTime', Status = 'Active');
        insert new List<ProductSellingModel>{ monthly, oneTime };

        Product2 internet = new Product2(Name = 'Test Fiber 1G', ProductCode = 'T-INT', IsActive = true, Type = 'Bundle',
            ConfigureDuringSale = 'Allowed', NF_AccessTechnology__c = 'Fiber', NF_DownloadMbps__c = 1000, NF_Highlights__c = 'Fast\nReliable', NF_DisplayOrder__c = 1);
        Product2 tooFast = new Product2(Name = 'Test Fiber 5G', ProductCode = 'T-INT5', IsActive = true,
            NF_AccessTechnology__c = 'Fiber', NF_DownloadMbps__c = 5000);
        Product2 mobile = new Product2(Name = 'Test Mobile', ProductCode = 'T-MOB', IsActive = true, NF_AccessTechnology__c = 'Any');
        Product2 router = new Product2(Name = 'Test Router', ProductCode = 'T-RTR', IsActive = true);
        Product2 install = new Product2(Name = 'Test Install', ProductCode = 'T-INS', IsActive = true);
        Product2 mesh = new Product2(Name = 'Test Mesh', ProductCode = 'T-MESH', IsActive = true);
        List<Product2> products = new List<Product2>{ internet, tooFast, mobile, router, install, mesh };
        insert products;

        Id stdPb = Test.getStandardPricebookId();
        List<PricebookEntry> pbes = new List<PricebookEntry>();
        List<ProductSellingModelOption> psmos = new List<ProductSellingModelOption>();
        for (Product2 p : products) {
            ProductSellingModel psm = p == install ? oneTime : monthly;
            psmos.add(new ProductSellingModelOption(Product2Id = p.Id, ProductSellingModelId = psm.Id, IsDefault = true));
            pbes.add(new PricebookEntry(Pricebook2Id = stdPb, Product2Id = p.Id, UnitPrice = 10, IsActive = true,
                ProductSellingModelId = psm.Id));
        }
        insert psmos;
        insert pbes;

        ProductCatalog cat = new ProductCatalog(Name = 'Test NF', Code = NF_OfferService.CATALOG_CODE, CatalogType = 'Sales');
        insert cat;
        // Multi-site browses the business catalog (the fake Discovery serves the same test products for it).
        ProductCatalog biz = new ProductCatalog(Name = 'Test NF Business', Code = NF_OfferService.BUSINESS_CATALOG_CODE, CatalogType = 'Sales');
        insert biz;
        ProductCategory bInternet = new ProductCategory(Name = 'Business Fiber', Code = 'NFB_CAT_FIBER', CatalogId = biz.Id, IsNavigational = true, SortOrder = 1);
        ProductCategory bMobile = new ProductCategory(Name = 'Business Mobile', Code = 'NFB_CAT_MOBILE', CatalogId = biz.Id, IsNavigational = true, SortOrder = 2);
        insert new List<ProductCategory>{ bInternet, bMobile };
        ProductCategory cInternet = new ProductCategory(Name = 'Fiber Internet', Code = 'NF_CAT_FIBER', CatalogId = cat.Id, IsNavigational = true, SortOrder = 1);
        ProductCategory cMobile = new ProductCategory(Name = 'Mobile', Code = 'NF_CAT_MOBILE', CatalogId = cat.Id, IsNavigational = true, SortOrder = 2);
        insert new List<ProductCategory>{ cInternet, cMobile };
        insert new List<ProductCategoryProduct>{
            new ProductCategoryProduct(ProductCategoryId = cInternet.Id, ProductId = internet.Id),
            new ProductCategoryProduct(ProductCategoryId = cInternet.Id, ProductId = tooFast.Id),
            new ProductCategoryProduct(ProductCategoryId = cMobile.Id, ProductId = mobile.Id),
            new ProductCategoryProduct(ProductCategoryId = bInternet.Id, ProductId = internet.Id),
            new ProductCategoryProduct(ProductCategoryId = bMobile.Id, ProductId = mobile.Id)
        };

        ProductRelationshipType rel = new ProductRelationshipType(Name = 'NF Test Bundle',
            MainProductRoleCat = 'Bundle', AssociatedProductRoleCat = 'BundleComponent');
        insert rel;
        ProductComponentGroup equip = new ProductComponentGroup(Name = 'Equipment', ParentProductId = internet.Id,
            MinBundleComponents = 1, MaxBundleComponents = 2, Sequence = 1);
        ProductComponentGroup inst = new ProductComponentGroup(Name = 'Installation', ParentProductId = internet.Id,
            MinBundleComponents = 1, MaxBundleComponents = 1, Sequence = 2);
        insert new List<ProductComponentGroup>{ equip, inst };
        insert new List<ProductRelatedComponent>{
            new ProductRelatedComponent(ParentProductId = internet.Id, ChildProductId = router.Id, ProductComponentGroupId = equip.Id,
                ProductRelationshipTypeId = rel.Id, IsComponentRequired = true, IsDefaultComponent = true, Quantity = 1, Sequence = 1),
            new ProductRelatedComponent(ParentProductId = internet.Id, ChildProductId = mesh.Id, ProductComponentGroupId = equip.Id,
                ProductRelationshipTypeId = rel.Id, IsQuantityEditable = true, Quantity = 1, MinQuantity = 1, MaxQuantity = 3, Sequence = 2),
            new ProductRelatedComponent(ParentProductId = internet.Id, ChildProductId = install.Id, ProductComponentGroupId = inst.Id,
                ProductRelationshipTypeId = rel.Id, IsDefaultComponent = true, Quantity = 1)
        };

        insert new Account(Name = 'Acme Household');

        // Shared configurator workspace (never saved to)
        Account wsAccount = new Account(Name = 'NovaFiber Configurator Workspace');
        insert wsAccount;
        insert new Quote(Name = NF_QuoteService.WORKSPACE_NAME, QuoteAccountId = wsAccount.Id, Pricebook2Id = stdPb);
    }

    private static User newUser(Boolean agent) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniq = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User u = new User(Alias = 'nft' + uniq.left(4), Email = 'nf' + uniq + '@example.com', EmailEncodingKey = 'UTF-8',
            LastName = 'NF Test', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York', UserName = 'nf' + uniq + '@novafiber.test');
        insert u;
        if (agent) {
            Id ps = [SELECT Id FROM PermissionSet WHERE Name = 'NF_Guided_Selling' LIMIT 1].Id;
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps);
        }
        return u;
    }

    private static String addressJson(String postalCode) {
        return '{"street":"1 Test St","city":"New York","state":"NY","postalCode":"' + postalCode + '","country":"US"}';
    }

    private static NF_JourneyModels.ServiceabilityResult serviceable() {
        Test.setMock(HttpCalloutMock.class, new ServiceabilityMock(200, FIBER_BODY));
        return apiCheck(addressJson('10001'));
    }

    /** Cart with the first offer (the fiber bundle) and its default options. */
    private static NF_JourneyModels.CartRequest cartFor(NF_JourneyModels.ServiceabilityResult svc, Decimal discount) {
        NF_JourneyModels.Offer offer = apiOffers(JSON.serialize(svc))[0].offers[0];
        NF_JourneyModels.CartItem item = new NF_JourneyModels.CartItem();
        item.key = 'item-1';
        item.productId = offer.productId;
        item.quantity = 1;
        item.discountPercent = discount;
        item.options = new List<NF_JourneyModels.SelectedOption>();
        for (NF_JourneyModels.OptionGroup g : offer.groups) {
            for (NF_JourneyModels.Option op : g.options) {
                if (op.isDefault) item.options.add(selected(op.componentId, op.defaultQuantity));
            }
        }
        NF_JourneyModels.CartRequest cart = new NF_JourneyModels.CartRequest();
        cart.serviceability = svc;
        cart.items = new List<NF_JourneyModels.CartItem>{ item };
        return cart;
    }

    private static NF_JourneyModels.SelectedOption selected(String componentId, Integer qty) {
        NF_JourneyModels.SelectedOption so = new NF_JourneyModels.SelectedOption();
        so.componentId = componentId;
        so.quantity = qty;
        return so;
    }

    private static Id meshComponentId() {
        return [SELECT Id FROM ProductRelatedComponent WHERE ChildProduct.ProductCode = 'T-MESH'].Id;
    }

    // ── Tests ────────────────────────────────────────────────────────────────

    @IsTest
    static void selfServiceContextHasNoAgentPowers() {
        System.runAs(newUser(false)) {
            NF_JourneyModels.JourneyContext c = NF_JourneyController.getContext();
            Assert.areEqual(NF_JourneyModels.CHANNEL_SELF_SERVICE, c.channel);
            Assert.isFalse(c.canDiscount);
            Assert.isFalse(c.canSelectAccount);
        }
    }

    @IsTest
    static void offersAreQualifiedBySpeedAndTechnology() {
        System.runAs(newUser(false)) {
            Test.startTest();
            NF_JourneyModels.ServiceabilityResult svc = serviceable();
            List<NF_JourneyModels.OfferCategory> cats = apiOffers(JSON.serialize(svc));
            Test.stopTest();

            Assert.areEqual(2, cats.size(), 'internet + mobile');
            Assert.areEqual(1, cats[0].offers.size(), '5 Gbps plan exceeds the 1 Gbps max speed');
            NF_JourneyModels.Offer o = cats[0].offers[0];
            Assert.areEqual('Fiber', o.technology);
            Assert.areEqual(2, o.highlights.size());
            Assert.areEqual(2, o.groups.size());
            Assert.areEqual('One-Time', o.groups[1].options[0].chargeType);
            Assert.isNotNull(o.priceBookEntryId, 'configurator references come from Discovery');
            Assert.isNotNull(o.groups[0].options[0].relationshipTypeId);
        }
    }

    @IsTest
    static void notServiceableOnlyOffersMobile() {
        System.runAs(newUser(false)) {
            Test.setMock(HttpCalloutMock.class, new ServiceabilityMock(200, NONE_BODY));
            Test.startTest();
            NF_JourneyModels.ServiceabilityResult svc = apiCheck(addressJson('99501'));
            List<NF_JourneyModels.OfferCategory> cats = apiOffers(JSON.serialize(svc));
            Test.stopTest();
            Assert.areEqual('NOT_SERVICEABLE', svc.status);
            Assert.areEqual(1, cats.size());
            Assert.areEqual('T-MOB', cats[0].offers[0].productCode);
        }
    }

    @IsTest
    static void serviceabilityErrorsAreFriendly() {
        System.runAs(newUser(false)) {
            Test.setMock(HttpCalloutMock.class, new ServiceabilityMock(500, 'oops'));
            Test.startTest();
            try {
                apiCheck(addressJson('10001'));
                Assert.fail('expected error');
            } catch (ApiErrorException e) {
                Assert.isTrue(e.getMessage().contains('HTTP 500'), e.getMessage());
            }
            try {
                apiCheck(addressJson('ABC'));
                Assert.fail('expected error');
            } catch (ApiErrorException e) {
                Assert.isTrue(e.getMessage().contains('ZIP'), e.getMessage());
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void cartChangesRunInWorkspaceSessions() {
        Integer quotesBefore = [SELECT COUNT() FROM Quote];
        System.runAs(newUser(false)) {
            Test.startTest();
            NF_JourneyModels.QuoteSummary opened = (NF_JourneyModels.QuoteSummary) unwrap(
                NF_JourneyController.startCart(true, null), NF_JourneyModels.QuoteSummary.class);
            Assert.isNotNull(opened.contextId, 'session opened before the first cart change');

            NF_JourneyModels.CartRequest cart = cartFor(serviceable(), null);
            cart.contextId = opened.contextId;
            cart.lineIds = new List<String>();
            NF_JourneyModels.QuoteSummary first = apiSync(cart);
            Assert.areEqual(opened.contextId, first.contextId, 'the pre-opened session is used');
            Assert.isNull(first.quoteId, 'no quote until the customer confirms');
            Assert.areEqual(3, first.lines.size(), 'bundle + router + install');
            Assert.areEqual('item-1', first.lines[0].itemKey);
            Assert.areEqual(20, first.monthlyTotal, 'bundle + router');
            Assert.areEqual(10, first.oneTimeTotal, 'install');
            Assert.isTrue(first.messages.isEmpty());
            Assert.isTrue(traceHas('RC_API') && traceHas('RULE') && traceHas('CACHE'));

            // Add the mesh in the same session: the rule message comes back on the cart item
            cart.lineIds = new List<String>();
            for (NF_JourneyModels.QuoteLine l : first.lines) cart.lineIds.add(l.lineId);
            cart.items[0].options.add(selected(meshComponentId(), 2));
            NF_JourneyModels.QuoteSummary second = apiSync(cart);
            Assert.areEqual(first.contextId, second.contextId, 'session reused');

            // An expired session is replaced transparently
            cart.contextId = 'expiredSession0001';
            NF_JourneyModels.QuoteSummary third = apiSync(cart, NF_JourneyCache.MODE_REALTIME);
            Assert.areEqual(4, third.lines.size());
            Boolean reopened = false;
            for (NF_Trace.Entry e : lastTrace) reopened |= e.label == 'Configurator session not reusable';
            Assert.isTrue(reopened);
            Test.stopTest();

            Assert.areEqual(4, second.lines.size());
            Assert.areEqual(1, second.messages.size());
            Assert.areEqual(MESH_RULE, second.messages[0].message);
            Assert.areEqual('item-1', second.messages[0].itemKey);
            Assert.areEqual('warning', second.messages[0].severity);
        }
        Assert.areEqual(quotesBefore, [SELECT COUNT() FROM Quote], 'cart edits create no quotes');
        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Name LIKE 'NovaFiber Prospect%'], 'cart edits create no accounts');
        Assert.areEqual(0, [SELECT COUNT() FROM QuoteLineItem], 'the workspace is never saved to');
    }

    @IsTest
    static void selfServiceQuoteAndOrder() {
        System.runAs(newUser(false)) {
            Test.startTest();
            NF_JourneyModels.CartRequest cart = cartFor(serviceable(), null);
            NF_JourneyModels.QuoteSummary q = apiPrice(cart);
            Assert.isTrue(q.isSaved);
            Assert.areEqual(3, [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.quoteId], 'lines placed on the quote');
            Assert.areEqual(3, q.lines.size());
            Quote saved = [SELECT NF_Channel__c, NF_ServiceabilityRef__c, QuoteAccount.Name,
                (SELECT Id FROM QuoteLineItemRecipients) FROM Quote WHERE Id = :q.quoteId];
            Assert.areEqual('SVC-1', saved.NF_ServiceabilityRef__c);
            Assert.areEqual(NF_JourneyModels.CHANNEL_SELF_SERVICE, saved.NF_Channel__c);
            Assert.isTrue(saved.QuoteAccount.Name.startsWith(NF_QuoteService.PROSPECT_PREFIX));
            Assert.areEqual(1, saved.QuoteLineItemRecipients.size(), 'service location');
            Assert.areEqual(3, [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.quoteId AND QuoteLineItemRecipientId != null]);

            // Back to the plans, change the cart, confirm again: same quote, lines replaced
            cart.quoteId = q.quoteId;
            cart.items[0].options.add(selected(meshComponentId(), 2));
            NF_JourneyModels.QuoteSummary again = apiPrice(cart);
            Assert.areEqual(q.quoteId, again.quoteId);
            Assert.areEqual(4, [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.quoteId]);

            NF_JourneyModels.OrderResult r = apiSubmit(q.quoteId,
                '{"firstName":"Ada","lastName":"Lovelace","email":"ada@example.com","phone":"(212) 555-0100","acceptedTerms":true,"portalPassword":"NovaFiber2026"}');
            Assert.isTrue(traceHas('RC_API'), 'createOrderFromQuote through the Revenue Cloud API');
            Test.stopTest();

            Assert.isNotNull(r.orderId);
            Assert.isNull(r.pendingRequestKey, 'placed synchronously');
            Assert.areEqual('Ada Lovelace', r.accountName);
            Order saved2 = [SELECT NF_Channel__c, QuoteId, BillToContact.Email FROM Order WHERE Id = :r.orderId];
            Assert.areEqual('ada@example.com', saved2.BillToContact.Email);
            Assert.areEqual(NF_JourneyModels.CHANNEL_SELF_SERVICE, saved2.NF_Channel__c);
            Assert.areEqual(q.quoteId, saved2.QuoteId);
            Assert.areEqual(1, fake.droSubmissions, 'the confirmed order goes to DRO');
            Assert.areEqual('Submitted', r.fulfillmentStatus);
            Assert.isTrue(r.submittedToFulfillment);
            try {
                apiSubmit(q.quoteId, '{"firstName":"Ada","lastName":"Lovelace","email":"ada@example.com","phone":"2125550100","acceptedTerms":true,"portalPassword":"NovaFiber2026"}');
                Assert.fail('ordered twice');
            } catch (ApiErrorException e) {
                Assert.isTrue(e.getMessage().contains('already been ordered'), e.getMessage());
            }
        }
    }

    @IsTest
    static void serverCopyOfServiceabilityIsUsed() {
        System.runAs(newUser(false)) {
            Test.startTest();
            NF_JourneyModels.ServiceabilityResult svc = serviceable();
            // A tampered browser copy claiming multi-gig fiber: the server keeps using what it issued (1 Gbps)
            NF_JourneyModels.ServiceabilityResult tampered = (NF_JourneyModels.ServiceabilityResult)
                JSON.deserialize(JSON.serialize(svc), NF_JourneyModels.ServiceabilityResult.class);
            tampered.technologies[0].maxDownloadMbps = 10000;
            NF_JourneyModels.CartRequest cart = cartFor(svc, null);
            cart.serviceability = tampered;
            cart.items[0].productId = [SELECT Id FROM Product2 WHERE ProductCode = 'T-INT5'].Id;
            cart.items[0].options.clear();
            try {
                apiSync(cart);
                Assert.fail('the 5 Gbps plan is not available at this address');
            } catch (ApiErrorException e) {
                Assert.isTrue(e.getMessage().contains('not available'), e.getMessage());
            }
            // A check the server doesn't know (expired copy) is re-checked with the network
            NF_JourneyModels.CartRequest unknown = cartFor(svc, null);
            unknown.serviceability.serviceabilityId = 'SVC-expired';
            NF_JourneyModels.QuoteSummary live = apiSync(unknown);
            Assert.areEqual(3, live.lines.size());
            Boolean rechecked = false;
            for (NF_Trace.Entry e : lastTrace) rechecked |= e.label == 'Serviceability re-checked';
            Assert.isTrue(rechecked);
            Test.stopTest();
        }
    }

    @IsTest
    static void configuratorAndPlacementErrors() {
        System.runAs(newUser(false)) {
            Test.startTest();
            NF_JourneyModels.CartRequest cart = cartFor(serviceable(), null);
            fake.failPlace = true;
            try {
                apiPrice(cart);
                Assert.fail('Place Sales Transaction failed');
            } catch (ApiErrorException e) {
                Assert.isTrue(e.getMessage().contains('could not save your quote'), e.getMessage());
            }
            fake.failPlace = false;
            fake.ruleError = true;
            NF_JourneyModels.QuoteSummary live = apiSync(cart);
            Assert.isTrue(live.hasErrors, 'cart edits show rule errors');
            Assert.isNull(live.messages[0].itemKey, 'quote-level message');
            fake.ruleError = false;
            fake.failConfigure = true;
            try {
                apiSync(cart, NF_JourneyCache.MODE_REALTIME);
                Assert.fail('configurator failure');
            } catch (ApiErrorException e) {
                Assert.isTrue(e.getMessage().contains('could not update your cart'), e.getMessage());
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void selfServiceCannotDiscountOrSkipRequiredOptions() {
        System.runAs(newUser(false)) {
            Test.startTest();
            NF_JourneyModels.ServiceabilityResult svc = serviceable();
            try {
                apiSync(cartFor(svc, 10));
                Assert.fail('discount must be rejected');
            } catch (ApiErrorException e) {
                Assert.isTrue(e.getMessage().contains('Discounts are not allowed'), e.getMessage());
            }
            NF_JourneyModels.CartRequest cart = cartFor(svc, null);
            cart.items[0].options.clear();
            try {
                apiPrice(cart);   // cart edits leave bundle judgement to the configurator; saving enforces it
                Assert.fail('required option must be enforced');
            } catch (ApiErrorException e) {
                Assert.isTrue(e.getMessage().contains('required'), e.getMessage());
            }
            cart.items[0].options.add(selected('0dS000000000000AAA', 1));
            try {
                apiSync(cart);
                Assert.fail('unknown option');
            } catch (ApiErrorException e) {
                Assert.isTrue(e.getMessage().contains('not available'), e.getMessage());
            }
            try {
                apiSync(new NF_JourneyModels.CartRequest());
                Assert.fail('empty cart');
            } catch (ApiErrorException e) {
                Assert.isTrue(e.getMessage().contains('empty'), e.getMessage());
            }
            try {
                apiSearch('Acme');
                Assert.fail('account search is agent only');
            } catch (ApiErrorException e) {
                Assert.isTrue(e.getMessage().contains('not allowed'), e.getMessage());
            }
            Test.stopTest();
        }
    }


    @IsTest
    static void agentCanDiscountOverrideAndPickAccount() {
        Account existing = [SELECT Id FROM Account WHERE Name = 'Acme Household'];
        System.runAs(newUser(true)) {
            NF_JourneyController.agentOverride = true;
            Test.startTest();
            NF_JourneyModels.JourneyContext ctx = NF_JourneyController.getContext();
            Assert.isTrue(ctx.isAgent);

            Test.setMock(HttpCalloutMock.class, new ServiceabilityMock(200, NONE_BODY));
            NF_JourneyModels.ServiceabilityResult svc = apiCheck(addressJson('99501'));
            svc = apiOverride(JSON.serialize(svc));
            Assert.isTrue(svc.overridden);

            NF_JourneyModels.CartRequest cart = cartFor(svc, 15);
            cart.accountId = existing.Id;
            NF_JourneyModels.QuoteSummary live = apiSync(cart);
            Assert.areEqual(15, live.lines[0].discountPercent);
            Assert.areEqual(17, live.monthlyTotal, '15% off 2 × 10');

            NF_JourneyModels.QuoteSummary q = apiPrice(cart);
            Assert.areEqual(existing.Id, q.accountId, 'quoted on the customer account');
            List<NF_JourneyModels.AccountMatch> matches = apiSearch('Acme');
            Test.stopTest();
            Assert.areEqual(1, matches.size());
            Assert.areEqual(NF_JourneyModels.CHANNEL_AGENT, [SELECT NF_Channel__c FROM Quote WHERE Id = :q.quoteId].NF_Channel__c);
        }
    }

    // ── Multi-site quoting ───────────────────────────────────────────────────

    private static String siteJson(String key, String name, String state, String postalCode) {
        return '{"key":"' + key + '","name":"' + name + '","address":{"street":"1 ' + name + ' St","city":"Testville",'
            + '"state":"' + state + '","postalCode":"' + postalCode + '","country":"US"}}';
    }

    /** A site's cart: its first offer (the fiber bundle) with the default options. */
    private static NF_JourneyModels.SiteCart siteCart(NF_JourneyModels.SiteResult site) {
        NF_JourneyModels.Offer offer = site.offers[0].offers[0];
        NF_JourneyModels.CartItem item = new NF_JourneyModels.CartItem();
        item.key = site.key + '-1';
        item.productId = offer.productId;
        item.quantity = 1;
        item.options = new List<NF_JourneyModels.SelectedOption>();
        for (NF_JourneyModels.OptionGroup g : offer.groups) {
            for (NF_JourneyModels.Option op : g.options) {
                if (op.isDefault) item.options.add(selected(op.componentId, op.defaultQuantity));
            }
        }
        NF_JourneyModels.SiteCart c = new NF_JourneyModels.SiteCart();
        c.key = site.key;
        c.name = site.name;
        c.serviceability = site.serviceability;
        c.items = new List<NF_JourneyModels.CartItem>{ item };
        return c;
    }

    private static void assertError(NF_JourneyModels.Envelope env, String expected) {
        Assert.isNotNull(env.error, 'expected an error containing "' + expected + '"');
        Assert.isTrue(env.error.contains(expected), env.error);
    }

    @IsTest
    static void multiSiteQuotingPricesEachSiteByItsState() {
        Map<String, Id> productIds = new Map<String, Id>();
        for (Product2 p : [SELECT Id, ProductCode FROM Product2]) productIds.put(p.ProductCode, p.Id);
        Id stdPb = Test.getStandardPricebookId();
        Id monthly = [SELECT ProductSellingModelId FROM PricebookEntry WHERE Product2Id = :productIds.get('T-INT')].ProductSellingModelId;
        NF_JourneyModels.MultiSiteQuote q;
        System.runAs(newUser(true)) {
            // Inside runAs: the user and permission set insert is setup DML (no mixed DML with the price rows).
            insert new List<ItemLocationPrice__c>{
                new ItemLocationPrice__c(Product__c = productIds.get('T-INT'), Price_Book__c = stdPb, Product_Selling_Model__c = monthly,
                    LocationState__c = 'NY', Unit_Price__c = 12),
                new ItemLocationPrice__c(Product__c = productIds.get('T-INT'), Price_Book__c = stdPb, Product_Selling_Model__c = monthly,
                    LocationState__c = 'TX', Unit_Price__c = 8)
            };
            NF_JourneyController.agentOverride = true;
            Test.setMock(HttpCalloutMock.class, new ServiceabilityMock(200, FIBER_BODY));
            Test.startTest();
            List<NF_JourneyModels.SiteResult> sites = (List<NF_JourneyModels.SiteResult>) unwrap(NF_JourneyController.checkSites(
                '[' + siteJson('hq', 'HQ', 'ny', '10001') + ',' + siteJson('austin', 'Austin store', 'TX', '73301') + ']', true, null),
                List<NF_JourneyModels.SiteResult>.class);
            Assert.areEqual(2, sites.size());
            Assert.isNull(sites[0].error);
            Assert.areEqual('NY', sites[0].serviceability.address.state, 'state codes are normalised');
            NF_JourneyModels.Offer bundle = sites[0].offers[0].offers[0];

            // Browsing: list prices per state from the location price table, nothing saved
            NF_JourneyModels.StatePriceRequest pr = new NF_JourneyModels.StatePriceRequest();
            pr.states = new List<String>{ 'NY', 'TX' };
            pr.productIds = new List<String>{ bundle.productId, productIds.get('T-MOB') };
            List<NF_JourneyModels.StatePrices> prices = (List<NF_JourneyModels.StatePrices>) unwrap(
                NF_JourneyController.getStatePrices(JSON.serialize(pr), true, null), List<NF_JourneyModels.StatePrices>.class);
            Assert.areEqual('NY', prices[0].state);
            Assert.areEqual(12, prices[0].prices.get(bundle.productId));
            Assert.areEqual(8, prices[1].prices.get(bundle.productId));
            Assert.areEqual(10, prices[1].prices.get(productIds.get('T-MOB')), 'no state row: the price book price');
            unwrap(NF_JourneyController.getStatePrices(JSON.serialize(pr), true, null), List<NF_JourneyModels.StatePrices>.class);
            Assert.isTrue(traceHas('CACHE'), 'the same day is served from the cache');

            // Each site's cart priced for its state
            List<NF_JourneyModels.SiteCart> carts = new List<NF_JourneyModels.SiteCart>{ siteCart(sites[0]), siteCart(sites[1]) };
            List<NF_JourneyModels.SiteSummary> priced = (List<NF_JourneyModels.SiteSummary>) unwrap(
                NF_JourneyController.priceSiteCarts(JSON.serialize(carts), true, null), List<NF_JourneyModels.SiteSummary>.class);
            Assert.areEqual(22, priced[0].monthlyTotal, 'NY bundle 12 + router 10');
            Assert.areEqual(18, priced[1].monthlyTotal, 'TX bundle 8 + router 10');
            Assert.areEqual(10, priced[1].oneTimeTotal, 'install');
            Assert.areEqual(3, priced[0].lines.size());

            // One quote: a service location and a line group per site
            NF_JourneyModels.MultiSiteRequest req = new NF_JourneyModels.MultiSiteRequest();
            req.companyName = 'Globex Corporation';
            req.sites = carts;
            q = (NF_JourneyModels.MultiSiteQuote) unwrap(
                NF_JourneyController.saveMultiSiteQuote(JSON.serialize(req), true, null), NF_JourneyModels.MultiSiteQuote.class);
            Test.stopTest();
        }
        Assert.areEqual(2, q.sites.size());
        Assert.areEqual(22, q.sites[0].monthlyTotal);
        Assert.areEqual(18, q.sites[1].monthlyTotal);
        Assert.areEqual(40, q.monthlyTotal);
        Assert.areEqual(20, q.oneTimeTotal);
        Quote saved = [SELECT QuoteAccount.Name, NF_Channel__c FROM Quote WHERE Id = :q.quoteId];
        Assert.areEqual('Globex Corporation', saved.QuoteAccount.Name);
        Assert.areEqual(NF_JourneyModels.CHANNEL_AGENT, saved.NF_Channel__c);
        Assert.areEqual(2, [SELECT COUNT() FROM QuoteLineItemRecipient WHERE QuoteId = :q.quoteId AND ServiceState IN ('NY', 'TX')]);
        Assert.areEqual(2, [SELECT COUNT() FROM QuoteLineGroup WHERE QuoteId = :q.quoteId]);
        Assert.areEqual(0, [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.quoteId
            AND (QuoteLineItemRecipientId = null OR QuoteLineGroupId = null)], 'every line belongs to its site');
        Assert.areEqual(2, [SELECT COUNT() FROM QuoteLineItemRecipient WHERE Quote.Name = :NF_MultiSiteService.PRICING_WORKSPACE],
            'one pricing location per state');
        Assert.areEqual(0, [SELECT COUNT() FROM QuoteLineItem WHERE Quote.Name = :NF_MultiSiteService.PRICING_WORKSPACE],
            'browsing never saves lines');
    }

    @IsTest
    static void siteVisitorsQuoteMultiSiteOnAProspectAccount() {
        Account existing = [SELECT Id FROM Account WHERE Name = 'Acme Household'];
        System.runAs(newUser(false)) {
            // Site visitors can quote several sites, but never on an existing account, and on a prospect account.
            Test.setMock(HttpCalloutMock.class, new ServiceabilityMock(200, FIBER_BODY));
            Test.startTest();
            List<NF_JourneyModels.SiteResult> sites = (List<NF_JourneyModels.SiteResult>) unwrap(
                NF_JourneyController.checkSites('[' + siteJson('a', 'A', 'NY', '10001') + ']', true, null),
                List<NF_JourneyModels.SiteResult>.class);
            Assert.isNull(sites[0].error, 'visitor site check: ' + sites[0].error);
            NF_JourneyModels.MultiSiteRequest req = new NF_JourneyModels.MultiSiteRequest();
            req.sites = new List<NF_JourneyModels.SiteCart>{ siteCart(sites[0]) };
            req.accountId = existing.Id;
            assertError(NF_JourneyController.saveMultiSiteQuote(JSON.serialize(req), true, null), 'not allowed');
            req.accountId = null;
            req.companyName = 'Visitor Corp';
            NF_JourneyModels.MultiSiteQuote q = (NF_JourneyModels.MultiSiteQuote) unwrap(
                NF_JourneyController.saveMultiSiteQuote(JSON.serialize(req), true, null), NF_JourneyModels.MultiSiteQuote.class);
            Assert.areEqual(NF_QuoteService.PROSPECT_PREFIX + ' - Visitor Corp',
                [SELECT QuoteAccount.Name FROM Quote WHERE Id = :q.quoteId].QuoteAccount.Name);
            Test.stopTest();
        }
    }

    @IsTest
    static void multiSiteIsForAgentsAndValidated() {
        System.runAs(newUser(true)) {
            NF_JourneyController.agentOverride = true;
            Test.setMock(HttpCalloutMock.class, new ServiceabilityMock(200, FIBER_BODY));
            Test.startTest();
            List<String> many = new List<String>();
            for (Integer i = 0; i <= NF_MultiSiteService.MAX_CHECK_BATCH; i++) many.add(siteJson('s' + i, 'S' + i, 'NY', '10001'));
            assertError(NF_JourneyController.checkSites('[' + String.join(many, ',') + ']', true, null), 'at most');

            List<NF_JourneyModels.SiteResult> bad = (List<NF_JourneyModels.SiteResult>) unwrap(
                NF_JourneyController.checkSites('[' + siteJson('x', 'X', 'New York', '10001') + ']', true, null),
                List<NF_JourneyModels.SiteResult>.class);
            Assert.isTrue(bad[0].error.contains('2-letter'), bad[0].error);

            assertError(NF_JourneyController.getStatePrices('{"states":["NY"],"productIds":["not-an-id"]}', true, null), 'Unknown product');
            assertError(NF_JourneyController.priceSiteCarts('[]', true, null), 'at least one site');

            List<NF_JourneyModels.SiteResult> ok = (List<NF_JourneyModels.SiteResult>) unwrap(
                NF_JourneyController.checkSites('[' + siteJson('hq', 'HQ', 'NY', '10001') + ']', true, null),
                List<NF_JourneyModels.SiteResult>.class);
            NF_JourneyModels.MultiSiteRequest req = new NF_JourneyModels.MultiSiteRequest();
            req.sites = new List<NF_JourneyModels.SiteCart>{ siteCart(ok[0]) };
            assertError(NF_JourneyController.saveMultiSiteQuote(JSON.serialize(req), true, null), 'business name');
            req.sites[0].items.clear();
            req.companyName = 'Globex';
            assertError(NF_JourneyController.saveMultiSiteQuote(JSON.serialize(req), true, null), 'has no plans');
            Test.stopTest();
        }
    }

    @IsTest
    static void discardingAJourneyDeletesItsRecords() {
        System.runAs(newUser(false)) {
            Test.startTest();
            NF_JourneyModels.QuoteSummary q = apiPrice(cartFor(serviceable(), null));
            Id accountId = q.accountId;
            Assert.areEqual(1, [SELECT COUNT() FROM Quote WHERE Id = :q.quoteId]);

            NF_JourneyModels.DiscardResult r = apiDiscard(q.quoteId);
            Assert.isTrue(r.discarded);
            Assert.areEqual(2, r.deleted.size(), 'quote + prospect account');
            Assert.areEqual(0, [SELECT COUNT() FROM Quote WHERE Id = :q.quoteId]);
            Assert.areEqual(0, [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :q.quoteId], 'lines cascade');
            Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Id = :accountId]);
            Assert.isTrue(traceHas('RC_API'));

            Assert.isTrue(apiDiscard(q.quoteId).deleted.isEmpty(), 'discarding twice is harmless');
            Assert.isTrue(apiDiscard(null).deleted.isEmpty(), 'nothing created yet');
            Test.stopTest();
        }
    }

    @IsTest
    static void orderedQuotesAndCustomerAccountsAreKept() {
        Account existing = [SELECT Id FROM Account WHERE Name = 'Acme Household'];
        Quote customerQuote = new Quote(Name = 'Agent draft', QuoteAccountId = existing.Id,
            Pricebook2Id = Test.getStandardPricebookId(), NF_Channel__c = NF_JourneyModels.CHANNEL_AGENT);
        Account prospect = new Account(Name = NF_QuoteService.PROSPECT_PREFIX + ' - ordered');
        insert prospect;
        Quote ordered = new Quote(Name = 'Ordered', QuoteAccountId = prospect.Id,
            Pricebook2Id = Test.getStandardPricebookId(), NF_Channel__c = NF_JourneyModels.CHANNEL_SELF_SERVICE);
        insert new List<Quote>{ customerQuote, ordered };
        insert new Order(AccountId = prospect.Id, QuoteId = ordered.Id, EffectiveDate = Date.today(), Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId());

        Test.startTest();
        NF_JourneyController.agentOverride = false;   // a customer, not an agent
        try {
            apiDiscard(ordered.Id);
            Assert.fail('ordered quotes are kept');
        } catch (ApiErrorException e) {
            Assert.isTrue(e.getMessage().contains('already been ordered'), e.getMessage());
        }
        try {
            apiDiscard(customerQuote.Id);
            Assert.fail('customers cannot discard a customer quote');
        } catch (ApiErrorException e) {
            Assert.isTrue(e.getMessage().contains('cannot be discarded'), e.getMessage());
        }
        NF_JourneyController.agentOverride = true;
        NF_JourneyModels.DiscardResult r = apiDiscard(customerQuote.Id);
        Test.stopTest();
        Assert.areEqual(1, r.deleted.size(), 'the agent draft goes, the customer account stays');
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Id = :existing.Id]);
    }

    @IsTest
    static void cleanupRemovesAbandonedJourneys() {
        Account prospect = new Account(Name = NF_QuoteService.PROSPECT_PREFIX + ' - abandoned');
        Account orphan = new Account(Name = NF_QuoteService.PROSPECT_PREFIX + ' - orphan');
        Account customer = [SELECT Id FROM Account WHERE Name = 'Acme Household'];
        insert new List<Account>{ prospect, orphan };
        Quote abandoned = new Quote(Name = 'Abandoned', QuoteAccountId = prospect.Id,
            Pricebook2Id = Test.getStandardPricebookId(), NF_Channel__c = NF_JourneyModels.CHANNEL_SELF_SERVICE);
        Quote customerDraft = new Quote(Name = 'Customer draft', QuoteAccountId = customer.Id,
            Pricebook2Id = Test.getStandardPricebookId(), NF_Channel__c = NF_JourneyModels.CHANNEL_AGENT);
        insert new List<Quote>{ abandoned, customerDraft };
        insert new NF_Journey_Request__c(Request_Key__c = 'old', Operation__c = 'SUBMIT_ORDER', Status__c = 'Completed');

        NF_JourneyCleanup.cutoffOverride = DateTime.now().addMinutes(5);
        Test.startTest();
        System.schedule('NF cleanup test', '0 0 3 * * ?', new NF_JourneyCleanup());
        Integer deleted = NF_JourneyCleanup.run();
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Quote WHERE Id = :abandoned.Id]);
        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Id IN (:prospect.Id, :orphan.Id)],
            'prospects without journeys go (the abandoned one in the next pass at the latest)');
        Assert.areEqual(1, [SELECT COUNT() FROM Quote WHERE Id = :customerDraft.Id], 'customer quotes are never cleaned up');
        Assert.areEqual(0, [SELECT COUNT() FROM NF_Journey_Request__c]);
        Assert.isTrue(deleted >= 3);
    }

    @IsTest
    static void serviceabilityHandlesGarbageAndAgentErrorsShowDetail() {
        NF_JourneyController.agentOverride = true;
        Test.setMock(HttpCalloutMock.class, new ServiceabilityMock(200, '<html>not json</html>'));
        Test.startTest();
        try {
            apiCheck(addressJson('10001'));
            Assert.fail('expected error');
        } catch (ApiErrorException e) {
            Assert.isTrue(e.getMessage().contains('unexpected response'), e.getMessage());
        }
        try {
            apiOffers('not json');
            Assert.fail('expected error');
        } catch (ApiErrorException e) {
            Assert.isTrue(e.getMessage().contains('JSONException'), 'agents see technical detail: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void failedOrdersChangeNothing() {
        System.runAs(newUser(false)) {
            Test.startTest();
            NF_JourneyModels.QuoteSummary q = apiPrice(cartFor(serviceable(), null));
            fake.failOrder = true;
            try {
                apiSubmit(q.quoteId, '{"firstName":"Ada","lastName":"Lovelace","email":"ada@example.com","phone":"2125550100","acceptedTerms":true,"portalPassword":"NovaFiber2026"}');
                Assert.fail('order failed');
            } catch (ApiErrorException e) {
                Assert.isTrue(e.getMessage().contains('could not place your order'), e.getMessage());
            }
            Test.stopTest();
            Assert.isTrue([SELECT Name FROM Account WHERE Id = :q.accountId].Name.startsWith(NF_QuoteService.PROSPECT_PREFIX),
                'the prospect is only renamed once the order exists');
            Assert.areEqual(0, [SELECT COUNT() FROM Contact WHERE AccountId = :q.accountId]);
        }
    }
    @IsTest
    static void workerRecordsFailuresSafely() {
        NF_Journey_Request__c r = new NF_Journey_Request__c(Request_Key__c = 'k1', Operation__c = 'SUBMIT_ORDER',
            Status__c = 'Pending', Payload__c = '{"quoteId":"0Q0000000000000AAA","customer":{},"ctx":{"isAgent":false}}');
        insert r;
        Test.startTest();
        NF_JourneyWorker.process(new List<NF_Journey_Signal__e>{ new NF_Journey_Signal__e(Request_Id__c = r.Id) });
        Test.stopTest();
        NF_JourneyWorker.RequestResult res = NF_JourneyWorker.poll('k1');
        Assert.areEqual('Failed', res.status);
        Assert.isTrue(res.error.contains('name'), res.error);
        try {
            apiPoll('nope');
            Assert.fail('unknown key');
        } catch (ApiErrorException e) {
            Assert.isTrue(e.getMessage().contains('expired'), e.getMessage());
        }
    }

    @IsTest
    static void inspectorTraceIsGatedAndMasked() {
        Test.setMock(HttpCalloutMock.class, new ServiceabilityMock(200, FIBER_BODY));
        Test.startTest();
        // Agent: always traced, nested callout + offer rule visible
        NF_JourneyController.agentOverride = true;
        NF_JourneyModels.ServiceabilityResult svc = apiCheck(addressJson('10001'));
        Assert.isTrue(traceHas('APEX') && traceHas('CALLOUT'), 'agent sees the callout');
        apiOffers(JSON.serialize(svc));
        Assert.isTrue(traceHas('RC_API') && traceHas('RULE'), 'agent sees the Revenue Cloud calls and qualification');

        // Guest-like caller without the site switch: no trace even when debug is requested
        NF_JourneyController.agentOverride = false;
        NF_JourneyController.guestDebugOverride = false;
        apiCheck(addressJson('10001'));
        Assert.isNull(lastTrace, 'no inspector unless the setting allows it');

        // Switch on: debug=true traces, debug=false does not
        NF_JourneyController.guestDebugOverride = true;
        apiCheck(addressJson('10001'));
        Assert.isNotNull(lastTrace);
        NF_JourneyModels.Envelope quiet = NF_JourneyController.getCatalogPreview(false, null);
        Assert.isNull(quiet.trace);
        Assert.isNotNull(quiet.dataJson, 'catalog preview for the landing page');
        Test.stopTest();

        Assert.isFalse(NF_Trace.mask('{"email":"ada@example.com","phone":"2125550142"}').contains('ada@example.com'));
        Assert.isFalse(NF_Trace.mask('call 212-555-0142').contains('555-01'));
        String big = NF_Trace.toJson('x'.repeat(25000));
        Assert.isTrue(big.contains('truncated'), 'large payloads are capped before masking');
    }

    /** Revenue Cloud answers, but qualification failed (e.g. the context could not hydrate). */
    private class FailedQualification implements NF_RevCloudApi.Responder {
        public String respond(String method, String path, String requestBody) {
            return '{"apiStatus":{"statusCode":"ProductQualificationFailed","messages":[{"message":"We couldn\'t fetch the data"}]},'
                + '"result":[{"id":"01t000000000001AAA","name":"Everything","qualificationContext":{}}]}';
        }
    }

    @IsTest
    static void failedQualificationNeverOffersEverything() {
        NF_RevCloudApi.responder = new FailedQualification();
        System.runAs(newUser(false)) {
            Test.startTest();
            NF_JourneyModels.ServiceabilityResult svc = serviceable();
            try {
                apiOffers(JSON.serialize(svc));
                Assert.fail('expected error');
            } catch (ApiErrorException e) {
                Assert.isTrue(e.getMessage().contains('which plans are available'), e.getMessage());
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void revCloudApiErrorsAreReported() {
        Assert.areEqual('bad thing', NF_RevCloudApi.firstError(JSON.deserializeUntyped('[{"errorCode":"X","message":"bad thing"}]')));
        Assert.areEqual('nested', NF_RevCloudApi.firstError(JSON.deserializeUntyped('{"errors":[{"message":"nested"}]}')));
        NF_RevCloudApi.responder = null;
        Test.setMock(HttpCalloutMock.class, new AnyCalloutMock(500, '[{"errorCode":"E","message":"boom"}]'));
        Test.startTest();
        try {
            NF_RevCloudApi.get('/connect/cpq/products', 'test');
            Assert.fail('expected error');
        } catch (NF_RevCloudApi.RevCloudException e) {
            Assert.isTrue(e.getMessage().contains('boom') && e.getMessage().contains('500'), e.getMessage());
        }
        Test.setMock(HttpCalloutMock.class, new AnyCalloutMock(200, '[{"a":1}]'));
        Assert.areEqual(1, NF_RevCloudApi.postList('/actions/standard/x', new Map<String, Object>(), 'test').size());
        Map<String, Object> withHeaders = NF_RevCloudApi.post('/sobjects/Account', new Map<String, Object>(), 'test',
            new Map<String, String>{ 'Sforce-Duplicate-Rule-Header' => 'allowSave=true' });
        Assert.isNotNull(withHeaders.get('result'));
        Test.stopTest();
    }

    @IsTest
    static void cachedJourneyServesRepeatedStepsAndRealtimeGoesLive() {
        System.runAs(newUser(false)) {
            Test.setMock(HttpCalloutMock.class, new ServiceabilityMock(200, FIBER_BODY));
            Test.startTest();
            // Cached (org default): the second check of an address comes from the cache
            apiCheck(addressJson('10001'));
            NF_JourneyModels.ServiceabilityResult svc = apiCheck(addressJson('10001'));
            Assert.isFalse(traceHas('CALLOUT'), 'no network call for a cached address');
            Assert.isTrue(traceHas('CACHE'));

            NF_JourneyModels.CartRequest cart = cartFor(svc, null);
            NF_JourneyModels.QuoteSummary first = apiSync(cart);
            Assert.isTrue(first.fromCache != true);
            Assert.isFalse(first.sessionLineIds.isEmpty());
            cart.contextId = first.contextId;
            cart.lineIds = first.sessionLineIds;
            NF_JourneyModels.QuoteSummary again = apiSync(cart);
            Assert.isTrue(again.fromCache, 'the same cart is priced from the cache');
            Assert.isFalse(traceHas('RC_API'), 'no configurator call');
            Assert.areEqual(first.monthlyTotal, again.monthlyTotal);
            Assert.areEqual('item-1', again.lines[0].itemKey, 'mapped onto this cart');
            Assert.areEqual(first.sessionLineIds, again.sessionLineIds, 'the session is untouched');

            // Realtime: every step goes live
            NF_JourneyController.checkServiceability(addressJson('10001'), true, NF_JourneyCache.MODE_REALTIME);
            NF_JourneyModels.Envelope live = NF_JourneyController.checkServiceability(addressJson('10001'), true, NF_JourneyCache.MODE_REALTIME);
            lastTrace = live.trace;
            Assert.isTrue(traceHas('CALLOUT'), 'realtime always calls the network');
            NF_JourneyModels.QuoteSummary realtime = apiSync(cart, NF_JourneyCache.MODE_REALTIME);
            Assert.isTrue(realtime.fromCache != true);
            Assert.isTrue(traceHas('RC_API'));
            Test.stopTest();
        }
    }

    @IsTest
    static void agentsCanFlushTheJourneyCache() {
        Test.setMock(HttpCalloutMock.class, new ServiceabilityMock(200, FIBER_BODY));
        Test.startTest();
        NF_JourneyController.agentOverride = false;
        NF_JourneyModels.Envelope denied = NF_JourneyController.flushJourneyCache(true);
        Assert.isTrue(denied.error.contains('not allowed'), denied.error);

        NF_JourneyController.agentOverride = true;
        Assert.isTrue(NF_JourneyController.getContext().canFlushCache);
        NF_JourneyModels.CartRequest cart = cartFor(serviceable(), null);
        apiSync(cart);
        Assert.isTrue(apiSync(cart).fromCache);
        NF_JourneyModels.Envelope flushed = NF_JourneyController.flushJourneyCache(true);
        Assert.isNull(flushed.error);
        Assert.isTrue(apiSync(cart).fromCache != true, 'flushed entries are stale');
        Test.stopTest();
        Assert.isNotNull(NF_JourneyCache.defaultMode());
    }

    @IsTest
    static void customerValidation() {
        NF_JourneyModels.JourneyContext ctx = NF_JourneyController.context();
        ctx.isAgent = false;
        NF_JourneyModels.CustomerDetails c = new NF_JourneyModels.CustomerDetails();
        c.firstName = 'A'; c.lastName = 'B'; c.email = 'bad'; c.phone = '1';
        for (String expected : new List<String>{ 'email', 'phone', 'terms', 'password' }) {
            try {
                NF_OrderService.validateCustomer(c, ctx);
                Assert.fail('expected ' + expected);
            } catch (NF_JourneyModels.JourneyException e) {
                Assert.isTrue(e.getMessage().containsIgnoreCase(expected), e.getMessage());
            }
            if (expected == 'email') c.email = 'a@b.co';
            if (expected == 'phone') c.phone = '2125550100';
            if (expected == 'terms') c.acceptedTerms = true;
        }
        c.portalPassword = 'NovaFiber2026';
        NF_OrderService.validateCustomer(c, ctx);   // a self-service customer with a password is fine
    }

    // ── AI sales agent (Agentforce) ──────────────────────────────────────────

    /** Stands in for the Agent API: a session per journey; each turn "the agent" runs its status action. */
    private class FakeAgent implements NF_RevCloudApi.Responder {
        String journeyKey;
        Integer turns = 0;
        public String respond(String method, String path, String requestBody) {
            if (method == 'DELETE') return '';
            Map<String, Object> req = (Map<String, Object>) JSON.deserializeUntyped(requestBody);
            if (path.startsWith('/agents/')) {
                journeyKey = (String) ((Map<String, Object>) ((List<Object>) req.get('variables'))[0]).get('value');
                return '{"sessionId":"sess-1","messages":[{"type":"Inform","message":"Hi, I am Nova."}]}';
            }
            turns++;
            Assert.areEqual(turns, ((Map<String, Object>) req.get('message')).get('sequenceId'));
            NF_AgentActionJourneyStatus.Request r = new NF_AgentActionJourneyStatus.Request();
            r.journeyKey = journeyKey;
            NF_AgentActionJourneyStatus.Result res = NF_AgentActionJourneyStatus.run(new List<NF_AgentActionJourneyStatus.Request>{ r })[0];
            return JSON.serialize(new Map<String, Object>{ 'messages' => new List<Object>{
                new Map<String, Object>{ 'type' => 'Inform', 'message' => 'You are at step ' + res.step + '.' } } });
        }
    }

    private static String newAgentJourney() {
        String key = 'k' + String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        insert new NF_Agent_Journey__c(Journey_Key__c = key, Session_Id__c = 'sess-x', Sequence__c = 0,
            State__c = JSON.serialize(new NF_AgentJourney.State()));
        return key;
    }

    private static NF_AgentActionCheckAddress.Result agentCheck(String key) {
        NF_AgentActionCheckAddress.Request r = new NF_AgentActionCheckAddress.Request();
        r.journeyKey = key;
        r.street = '1 Test St';
        r.city = 'New York';
        r.state = 'ny';
        r.postalCode = '10001';
        return NF_AgentActionCheckAddress.run(new List<NF_AgentActionCheckAddress.Request>{ r })[0];
    }

    private static NF_AgentActionUpdateCart.Result agentCart(String key, String op, String code, Decimal qty, String add, String remove) {
        NF_AgentActionUpdateCart.Request r = new NF_AgentActionUpdateCart.Request();
        r.journeyKey = key;
        r.operation = op;
        r.planCode = code;
        r.quantity = qty;
        r.addAddOns = add;
        r.removeAddOns = remove;
        return NF_AgentActionUpdateCart.run(new List<NF_AgentActionUpdateCart.Request>{ r })[0];
    }

    private static NF_AgentActionSaveQuote.Result agentQuote(String key) {
        NF_AgentActionSaveQuote.Request r = new NF_AgentActionSaveQuote.Request();
        r.journeyKey = key;
        return NF_AgentActionSaveQuote.run(new List<NF_AgentActionSaveQuote.Request>{ r })[0];
    }

    private static NF_AgentActionPlaceOrder.Result agentOrder(String key) {
        for (NF_Agent_Journey__c j : [SELECT Quote_Id__c FROM NF_Agent_Journey__c WHERE Journey_Key__c = :key AND Quote_Id__c != null]) {
            markSigned((Id) j.Quote_Id__c);
        }
        NF_AgentActionPlaceOrder.Request r = new NF_AgentActionPlaceOrder.Request();
        r.journeyKey = key;
        return NF_AgentActionPlaceOrder.run(new List<NF_AgentActionPlaceOrder.Request>{ r })[0];
    }

    @IsTest
    static void aiAgentRunsTheWholeJourney() {
        System.runAs(newUser(false)) {
            String key = newAgentJourney();
            Test.startTest();
            Test.setMock(HttpCalloutMock.class, new ServiceabilityMock(200, FIBER_BODY));


            NF_AgentActionCheckAddress.Result chk = agentCheck(key);
            Assert.isTrue(chk.success, chk.summary);
            Assert.areEqual('offers', chk.step);
            Assert.isTrue(chk.summary.contains('Fiber up to 1000 Mbps'), chk.summary);

            NF_AgentActionFindPlans.Request fp = new NF_AgentActionFindPlans.Request();
            fp.journeyKey = key;
            fp.category = 'internet';
            NF_AgentActionFindPlans.Result plans = NF_AgentActionFindPlans.run(new List<NF_AgentActionFindPlans.Request>{ fp })[0];
            Assert.isTrue(plans.summary.contains('[code T-INT]'), plans.summary);
            Assert.isFalse(plans.summary.contains('T-INT5'), 'not qualified at 1 Gbps');
            Assert.isTrue(plans.summary.contains('optional add-ons: Test Mesh'), plans.summary);

            NF_AgentActionUpdateCart.Result bad = agentCart(key, 'add', 'T-INT5', null, null, null);
            Assert.isFalse(bad.success, 'unqualified plans cannot be added');
            NF_AgentActionUpdateCart.Result added = agentCart(key, 'add', 'T-INT', null, 'mesh, laser beam', 'Test Router');
            Assert.isTrue(added.success, added.summary);
            Assert.areEqual('cart', added.step);
            Assert.isTrue(added.summary.contains(MESH_RULE), 'configurator rule message: ' + added.summary);
            Assert.isTrue(added.summary.contains('"laser beam" is not an option'), added.summary);
            Assert.isTrue(added.summary.contains('Test Router is required'), added.summary);
            agentCart(key, 'add', 'T-MOB', 2, null, null);

            NF_AgentActionPlaceOrder.Result early2 = agentOrder(key);
            Assert.isFalse(early2.success, 'no quote yet');

            NF_AgentActionSaveQuote.Result q = agentQuote(key);
            Assert.isTrue(q.success, q.summary);
            Assert.areEqual('quote', q.step);
            NF_AgentJourney.Journey j = NF_AgentJourney.load(key);
            Quote saved = [SELECT NF_Channel__c, QuoteAccount.Name, (SELECT Id FROM QuoteLineItems) FROM Quote WHERE Id = :j.state.quoteId];
            Assert.areEqual(NF_JourneyModels.CHANNEL_AI_AGENT, saved.NF_Channel__c);
            Assert.isTrue(saved.QuoteAccount.Name.startsWith(NF_QuoteService.PROSPECT_PREFIX));

            NF_AgentActionPlaceOrder.Result noDetails = agentOrder(key);
            Assert.isFalse(noDetails.success);
            Assert.isTrue(noDetails.summary.contains('secure checkout form'), noDetails.summary);

            NF_JourneyModels.CustomerDetails c = (NF_JourneyModels.CustomerDetails) JSON.deserialize(
                '{"firstName":"Ada","lastName":"Lovelace","email":"ada@example.com","phone":"2125550100","acceptedTerms":true,"portalPassword":"NovaFiber2026"}',
                NF_JourneyModels.CustomerDetails.class);
            j = NF_AgentJourney.load(key);
            NF_AgentJourney.saveCustomer(j, c);
            NF_AgentJourney.save(j, null);

            NF_AgentActionPlaceOrder.Result ordered = agentOrder(key);
            Assert.isTrue(ordered.success, ordered.summary);
            Assert.areEqual('done', ordered.step);
            NF_AgentActionPlaceOrder.Result again = agentOrder(key);
            Assert.isTrue(again.summary.contains('already placed'), again.summary);
            Test.stopTest();

            j = NF_AgentJourney.load(key);
            Assert.isNull(j.state.customer, 'contact details are not kept on the journey after the order');
            Order o = [SELECT NF_Channel__c, Account.Name FROM Order WHERE Id = :j.state.order.orderId];
            Assert.areEqual(NF_JourneyModels.CHANNEL_AI_AGENT, o.NF_Channel__c);
            Assert.areEqual('Ada Lovelace', o.Account.Name);
            List<NF_Trace.Entry> trace = NF_AgentJourney.pendingTrace(j.rec);
            Assert.isFalse(trace.isEmpty(), 'actions record their trace for the inspector');
            Assert.areEqual('AGENT_ACTION', trace[0].kind);
        }
    }

    @IsTest
    static void aiAgentCartChangesNeedANewQuote() {
        System.runAs(newUser(false)) {
            String key = newAgentJourney();
            Test.startTest();
            Test.setMock(HttpCalloutMock.class, new ServiceabilityMock(200, FIBER_BODY));
            agentCheck(key);
            NF_AgentActionShowAddOns.Request ar = new NF_AgentActionShowAddOns.Request();
            ar.journeyKey = key;
            Assert.isFalse(NF_AgentActionShowAddOns.run(new List<NF_AgentActionShowAddOns.Request>{ ar })[0].success, 'empty cart');
            agentCart(key, 'add', 'test fiber 1g', null, null, null);
            ar.planCode = 'T-INT';
            NF_AgentActionShowAddOns.Result addOns = NF_AgentActionShowAddOns.run(new List<NF_AgentActionShowAddOns.Request>{ ar })[0];
            Assert.isTrue(addOns.success, addOns.summary);
            Assert.isTrue(addOns.summary.contains('Test Mesh'), addOns.summary);
            Assert.isTrue(addOns.summary.contains('Test Router $10.00/month [required]'), addOns.summary);
            Assert.areEqual('addons', NF_AgentJourney.load(key).state.focus, 'the page brings the Add-ons section into view');
            Assert.isTrue(agentQuote(key).success);
            NF_AgentActionUpdateCart.Result upd = agentCart(key, 'update', 'T-INT', 2, null, null);
            Assert.isTrue(upd.success, upd.summary);
            Assert.areEqual('cart', upd.step, 'the saved quote no longer matches the cart');
            Assert.isFalse(agentCart(key, 'update', 'T-MOB', null, null, null).success, 'not in the cart');
            Assert.isFalse(agentCart(key, 'add', 'T-INT', 9, null, null).success, 'quantity limit');
            Assert.isFalse(agentCart(key, 'juggle', 'T-INT', null, null, null).success);
            NF_AgentActionUpdateCart.Result cleared = agentCart(key, 'clear', null, null, null, null);
            Assert.isTrue(cleared.summary.contains('empty'), cleared.summary);
            Assert.isFalse(agentQuote(key).success, 'empty cart');
            Test.stopTest();
            Assert.isTrue(NF_AgentJourney.status(NF_AgentJourney.load(key)).contains('Cart: empty'));
        }
    }

    @IsTest
    static void aiAgentUnknownJourneyAndBadAddress() {
        System.runAs(newUser(false)) {
            Test.startTest();
            NF_AgentActionCheckAddress.Result r = agentCheck('nope');
            Assert.isFalse(r.success);
            Assert.isTrue(r.summary.contains('expired'), r.summary);
            String key = newAgentJourney();
            NF_AgentActionCheckAddress.Request req = new NF_AgentActionCheckAddress.Request();
            req.journeyKey = key;
            req.street = '1 Test St';
            req.city = 'New York';
            req.state = 'NY';
            req.postalCode = '1000';
            Assert.isFalse(NF_AgentActionCheckAddress.run(new List<NF_AgentActionCheckAddress.Request>{ req })[0].success);
            NF_AgentActionFindPlans.Request early = new NF_AgentActionFindPlans.Request();
            early.journeyKey = key;
            NF_AgentActionFindPlans.Result none = NF_AgentActionFindPlans.run(new List<NF_AgentActionFindPlans.Request>{ early })[0];
            Assert.isFalse(none.success, 'plans need an address first');
            Test.stopTest();
        }
    }

    @IsTest
    static void websiteChatTalksToTheAgent() {
        NF_JourneyController.agentOverride = true;   // inspector trace on
        FakeAgent agent = new FakeAgent();
        NF_AgentApi.responder = agent;
        NF_AgentApi.agentIdOverride = '0Xx000000000001';
        Test.startTest();
        NF_JourneyModels.Envelope started = NF_AgentGateway.startChat(true);
        Assert.isNull(started.error, 'error: ' + started.error);
        Map<String, Object> v = (Map<String, Object>) JSON.deserializeUntyped(started.dataJson);
        String key = (String) v.get('journeyKey');
        Assert.areEqual(32, key.length(), '128-bit key');
        Assert.areEqual('Hi, I am Nova.', ((List<Object>) v.get('replies'))[0]);

        NF_JourneyModels.Envelope turn = NF_AgentGateway.sendMessage(key, 'hello', true);
        Assert.isNull(turn.error, 'error: ' + turn.error);
        v = (Map<String, Object>) JSON.deserializeUntyped(turn.dataJson);
        Assert.areEqual('You are at step address.', ((List<Object>) v.get('replies'))[0]);
        Boolean sawAction = false;
        for (NF_Trace.Entry e : turn.trace) if (e.kind == 'AGENT_ACTION') sawAction = true;
        Assert.isTrue(sawAction, 'the agent action trace is shown in the inspector');
        Assert.isNotNull(NF_AgentGateway.sendMessage(key, '  ', true).error, 'empty message');

        Assert.isNotNull(NF_AgentGateway.saveCustomer(key, '{"firstName":"Ada","lastName":"L","email":"bad","phone":"1"}', true).error);
        Assert.isNotNull(NF_AgentGateway.saveCustomer(key, 'not json', true).error);
        NF_JourneyModels.Envelope saved = NF_AgentGateway.saveCustomer(key,
            '{"firstName":"Ada","lastName":"Lovelace","email":"ada@example.com","phone":"2125550100","acceptedTerms":true,"portalPassword":"NovaFiber2026"}', true);
        Assert.isNull(saved.error, 'error: ' + saved.error);
        Assert.areEqual(true, ((Map<String, Object>) JSON.deserializeUntyped(saved.dataJson)).get('customerCaptured'));

        NF_JourneyModels.Envelope ended = NF_AgentGateway.endChat(key, true, true);
        Assert.isNull(ended.error, 'error: ' + ended.error);
        Test.stopTest();
        Assert.areEqual(0, [SELECT COUNT() FROM NF_Agent_Journey__c], 'discarded chats leave nothing behind');
        Assert.isNull(NF_AgentGateway.endChat(key, true, true).error, 'ending twice is harmless');
        Assert.isNotNull(NF_AgentGateway.sendMessage(key, 'hi', true).error, 'the chat is gone');
    }

    @IsTest
    static void agentApiErrorsAreFriendly() {
        String key = newAgentJourney();
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new AnyCalloutMock(401, '[{"errorCode":"INVALID_SESSION_ID","message":"Session expired"}]'));
        NF_JourneyModels.Envelope env = NF_AgentGateway.sendMessage(key, 'hello', false);
        Test.stopTest();
        Assert.areEqual('The assistant did not answer. Please try again.', env.error);
        Assert.areEqual(0, NF_AgentApi.texts(new Map<String, Object>{ 'messages' => 'x' }).size());
    }

    @IsTest
    static void cleanupRemovesOldAgentJourneys() {
        newAgentJourney();
        NF_JourneyCleanup.cutoffOverride = DateTime.now().addMinutes(5);
        Test.startTest();
        NF_JourneyCleanup.run();
        Test.stopTest();
        Assert.areEqual(0, [SELECT COUNT() FROM NF_Agent_Journey__c]);
    }
}