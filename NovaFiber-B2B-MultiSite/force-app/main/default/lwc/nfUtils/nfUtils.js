/**
 * Shared helpers for the NovaFiber guided selling components.
 */

export const STEPS = [
    { key: 'address', label: 'Address' },
    { key: 'offers', label: 'Plans' },
    { key: 'review', label: 'Quote' },
    { key: 'checkout', label: 'Details' },
    { key: 'sign', label: 'Sign' },
    { key: 'done', label: 'Order' }
];

/** Demo addresses mapped to the serviceability mock scenarios. */
export const SAMPLE_ADDRESSES = [
    { label: 'Multi-gig fiber (10001)', street: '350 5th Ave', city: 'New York', state: 'NY', postalCode: '10001' },
    { label: 'Fiber, new build (94105)', street: '415 Mission St', city: 'San Francisco', state: 'CA', postalCode: '94105' },
    { label: 'Copper / DSL 100 (60601)', street: '233 S Wacker Dr', city: 'Chicago', state: 'IL', postalCode: '60601' },
    { label: 'DSL 60 or 5G (30301)', street: '55 Trinity Ave SW', city: 'Atlanta', state: 'GA', postalCode: '30301' },
    { label: '5G only (73301)', street: '1100 Congress Ave', city: 'Austin', state: 'TX', postalCode: '73301' },
    { label: 'No home internet (99501)', street: '632 W 6th Ave', city: 'Anchorage', state: 'AK', postalCode: '99501' }
];

export const US_STATES = ['AL', 'AK', 'AZ', 'AR', 'CA', 'CO', 'CT', 'DE', 'DC', 'FL', 'GA', 'HI', 'ID', 'IL', 'IN', 'IA',
    'KS', 'KY', 'LA', 'ME', 'MD', 'MA', 'MI', 'MN', 'MS', 'MO', 'MT', 'NE', 'NV', 'NH', 'NJ', 'NM', 'NY', 'NC', 'ND', 'OH',
    'OK', 'OR', 'PA', 'RI', 'SC', 'SD', 'TN', 'TX', 'UT', 'VT', 'VA', 'WA', 'WV', 'WI', 'WY'].map((s) => ({ label: s, value: s }));

const currencyFormatters = {};

export function formatMoney(value, currencyCode = 'USD') {
    if (value === null || value === undefined || isNaN(value)) {
        return '';
    }
    if (!currencyFormatters[currencyCode]) {
        currencyFormatters[currencyCode] = new Intl.NumberFormat('en-US', { style: 'currency', currency: currencyCode });
    }
    return currencyFormatters[currencyCode].format(Number(value));
}

export function formatSpeed(mbps) {
    if (!mbps) {
        return '';
    }
    return mbps >= 1000 ? `${mbps / 1000} Gbps` : `${mbps} Mbps`;
}

/** Turns Apex/LDS errors into a single readable message. */
export function reduceError(error) {
    if (!error) {
        return 'Unknown error';
    }
    if (typeof error === 'string') {
        return error;
    }
    if (error.body) {
        if (Array.isArray(error.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        if (error.body.message) {
            return error.body.message;
        }
        if (error.body.pageErrors && error.body.pageErrors.length) {
            return error.body.pageErrors.map((e) => e.message).join(', ');
        }
    }
    return error.message || 'Unknown error';
}

let keySeq = 0;
export function nextKey(prefix = 'k') {
    keySeq += 1;
    return `${prefix}-${Date.now()}-${keySeq}`;
}

/**
 * Estimated (list price) totals for a cart item: { monthly, oneTime }.
 * item = { offer, quantity, options: { [componentId]: qty } }
 */
export function estimateItem(item) {
    const totals = { monthly: 0, oneTime: 0 };
    const add = (price, qty, chargeType) => {
        const amount = (Number(price) || 0) * qty;
        if (chargeType === 'One-Time') {
            totals.oneTime += amount;
        } else {
            totals.monthly += amount;
        }
    };
    add(item.offer.price, item.quantity, item.offer.chargeType);
    (item.offer.groups || []).forEach((g) => {
        g.options.forEach((op) => {
            const qty = item.options[op.componentId];
            if (qty) {
                add(op.price, qty * item.quantity, op.chargeType);
            }
        });
    });
    const discount = Number(item.discountPercent) || 0;
    if (discount > 0) {
        totals.monthly *= 1 - discount / 100;
        totals.oneTime *= 1 - discount / 100;
    }
    return totals;
}

/** Default option selection for an offer: { componentId: qty } for default/required options. */
export function defaultSelections(offer) {
    const sel = {};
    (offer.groups || []).forEach((g) => {
        g.options.forEach((op) => {
            if (op.isDefault || op.isRequired) {
                sel[op.componentId] = op.defaultQuantity || 1;
            }
        });
    });
    return sel;
}

/**
 * Serialises a UI cart into NF_JourneyModels.CartRequest JSON.
 * session = { quoteId, contextId, lineIds } of the cart's draft quote / configurator session, if any.
 */
export function toCartRequest(cart, serviceability, session, accountId) {
    return JSON.stringify({
        quoteId: session?.quoteId || null,
        contextId: session?.contextId || null,
        lineIds: session?.lineIds || null,
        accountId: accountId || null,
        serviceability,
        items: cart.map((item) => ({
            key: item.key,
            productId: item.offer.productId,
            quantity: item.quantity,
            discountPercent: item.discountPercent ? Number(item.discountPercent) : null,
            options: Object.keys(item.options)
                .filter((id) => item.options[id] > 0)
                .map((id) => ({ componentId: id, quantity: item.options[id] }))
        }))
    });
}

// ── Progress for slow steps (nfProgress) ────────────────────────────────────

const TIPS = {
    home: [
        'Every price you see comes live from Salesforce Revenue Cloud.',
        'Your plan, equipment and installation are kept together as one bundle on your quote.',
        'You can follow every step of your installation in My NovaFiber.',
        'No annual contract: your monthly price is locked for 24 months.'
    ],
    order: [
        'Your order goes straight to Dynamic Revenue Orchestrator, which plans the network, equipment, installation and billing.',
        'Your signed agreement is filed on your contract in Salesforce Contracts.',
        'Right after this you can pick your installation window.'
    ],
    business: [
        'Each site is priced for its own state from a location-based decision table.',
        'Every site gets its own service location and line group on one quote.',
        'Each site is fulfilled in its own lane, so sites can go live on their own schedule.'
    ]
};

const PROGRESS = {
    availability: {
        steps: [
            { label: 'Checking the network at your address', ms: 1200 },
            { label: 'Qualifying plans with Product Discovery', ms: 1400 },
            { label: 'Pricing the plans you can get', ms: 1500 }
        ],
        tips: TIPS.home
    },
    quote: {
        steps: [
            { label: 'Creating your customer record', ms: 1200 },
            { label: 'Creating the quote with the Sales Transaction API', ms: 1600 },
            { label: 'Pricing every line in Revenue Cloud', ms: 1600 },
            { label: 'Saving your bundle', ms: 1500 }
        ],
        tips: TIPS.home
    },
    order: {
        steps: [
            { label: 'Converting your quote into an order', ms: 2200 },
            { label: 'Adding your contact and activating your contract', ms: 2000 },
            { label: 'Activating the order', ms: 2000 },
            { label: 'Handing it to Dynamic Revenue Orchestrator', ms: 2200 },
            { label: 'Setting up your My NovaFiber login', ms: 1500 }
        ],
        tips: TIPS.order
    },
    checkSites: {
        steps: [
            { label: 'Checking the network at every site', ms: 2500 },
            { label: 'Qualifying the business catalog per site', ms: 2500 },
            { label: 'Loading prices for every state', ms: 2500 }
        ],
        tips: TIPS.business
    },
    statePrices: {
        steps: [
            { label: 'Opening a Revenue Cloud configurator session', ms: 1500 },
            { label: 'Pricing each product for each state', ms: 3000 },
            { label: 'Reading the location-based decision table', ms: 2000 }
        ],
        tips: TIPS.business
    },
    siteCarts: {
        steps: [
            { label: 'Configuring every site\'s cart', ms: 2500 },
            { label: 'Pricing every line for its site\'s state', ms: 3000 },
            { label: 'Checking bundle rules', ms: 2000 }
        ],
        tips: TIPS.business
    },
    msQuote: {
        steps: [
            { label: 'Creating the business account', ms: 1500 },
            { label: 'Creating the quote with a location and a line group per site', ms: 3000 },
            { label: 'Adding every site\'s lines, priced by state', ms: 4000 },
            { label: 'Summarizing the sites', ms: 2000 }
        ],
        tips: TIPS.business
    },
    msOrder: {
        steps: [
            { label: 'Converting the quote into an order', ms: 2500 },
            { label: 'Activating the order and the contract', ms: 2500 },
            { label: 'Handing it to Dynamic Revenue Orchestrator', ms: 2500 }
        ],
        tips: TIPS.business
    },
    agreement: {
        steps: [
            { label: 'Creating your contract from the quote (Salesforce Contracts)', ms: 2500 },
            { label: 'Data Mappers read the contract, your details and the quote lines', ms: 2500 },
            { label: 'Document Generation fills the Word template', ms: 3000 },
            { label: 'Converting your agreement to PDF', ms: 3000 }
        ],
        tips: [
            'No annual contract: cancel any time with 30 days\u2019 notice.',
            'Your monthly price is locked for 24 months.',
            'You\u2019ll sign with DocuSign right here on the page.',
            'The signed agreement is filed on your contract automatically.'
        ]
    },
    proposal: {
        steps: [
            { label: 'Stamping the sites, states and signatory on the quote', ms: 2000 },
            { label: 'Context Service hydrates NF_ProposalContext from the quote', ms: 3000 },
            { label: 'Document Generation fills the proposal template', ms: 3500 },
            { label: 'Filing the proposal as the contract document version', ms: 3500 }
        ],
        tips: TIPS.business
    }
};

/** Steps and tips for a busy message (or a key above); a single generic step otherwise. */
export function progressFor(messageOrKey) {
    const m = messageOrKey || '';
    const key = PROGRESS[m] ? m
        : m.startsWith('Checking availability') ? 'availability'
        : m.startsWith('Saving your quote') ? 'quote'
        : m.startsWith('Placing your order') ? 'order'
        : m.startsWith('Checking serviceability') ? 'checkSites'
        : m.includes('location prices') ? 'statePrices'
        : m.startsWith('Pricing every site') ? 'siteCarts'
        : m.startsWith('Creating the quote') ? 'msQuote'
        : m.startsWith('Creating the order') ? 'msOrder'
        : null;
    return key ? PROGRESS[key] : { steps: [{ label: m || 'Working', ms: 3000 }], tips: [] };
}
