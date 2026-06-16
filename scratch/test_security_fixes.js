const express = require('express');

// Mock dependencies so we do not need a live database or Google API keys
const mockDb = {
    query: async () => ({ rows: [] })
};
require.cache[require.resolve('../jot-server/src/db')] = {
    exports: mockDb
};

// Mock authentication middleware
require.cache[require.resolve('../jot-server/src/middleware/auth')] = {
    exports: {
        requireAuth: (req, res, next) => {
            req.user = { userId: 'test-user-id', email: 'test@example.com' };
            next();
        }
    }
};

// Mock googleapis and fetch
require.cache[require.resolve('googleapis')] = {
    exports: {
        google: {
            auth: { GoogleAuth: class {} },
            androidpublisher: () => ({
                purchases: {
                    products: {
                        get: async () => ({ data: { purchaseState: 0 } })
                    }
                }
            })
        }
    }
};

// Load routes
const billingRouter = require('../jot-server/src/routes/billing');
const aiRouter = require('../jot-server/src/routes/ai');

const app = express();
app.use(express.json());
app.use('/api/billing', billingRouter);
app.use('/api/ai', aiRouter);

// Test harness
async function runTests() {
    console.log('🧪 Starting Security Fix Tests...\n');
    let failures = 0;

    // Helper to simulate request
    const testRequest = async (method, path, body) => {
        return new Promise((resolve) => {
            const req = {
                method,
                url: path,
                headers: { 'content-type': 'application/json' },
                body
            };
            const res = {
                status(code) {
                    this.statusCode = code;
                    return this;
                },
                json(data) {
                    resolve({ status: this.statusCode || 200, data });
                }
            };
            app(req, res);
        });
    };

    // 1. Test Billing Quantity Validation
    console.log('1. Testing Billing Quantity Verification...');
    const billingCases = [
        { body: { productId: 'jot_credits_5', purchaseToken: 'tok', quantity: -5 }, expectedStatus: 400 },
        { body: { productId: 'jot_credits_5', purchaseToken: 'tok', quantity: 1.5 }, expectedStatus: 400 },
        { body: { productId: 'jot_credits_5', purchaseToken: 'tok', quantity: 'abc' }, expectedStatus: 400 }
    ];

    for (const c of billingCases) {
        const res = await testRequest('POST', '/api/billing/verify', c.body);
        if (res.status === c.expectedStatus) {
            console.log(`✅ Passed: quantity ${c.body.quantity} rejected with status ${res.status}`);
        } else {
            console.log(`❌ Failed: quantity ${c.body.quantity} returned status ${res.status} (expected ${c.expectedStatus})`);
            failures++;
        }
    }

    // 2. Test Subreddit SSRF Validation
    console.log('\n2. Testing Subreddit Parameter Security...');
    const subredditCases = [
        { subreddit: '../../invalid-path', expectedStatus: 400 },
        { subreddit: 'invalid spaces', expectedStatus: 400 },
        { subreddit: 'valid_name', expectedStatus: 200 } // status 200 means it passed validation (may error later on fetch, but bypassed regex validation)
    ];

    for (const c of subredditCases) {
        const res = await testRequest('POST', '/api/ai/fetch-subreddit', { subreddit: c.subreddit });
        if (c.expectedStatus === 400 && res.status === 400) {
            console.log(`✅ Passed: sub "${c.subreddit}" rejected with status 400`);
        } else if (c.expectedStatus === 200 && res.status !== 400) {
            console.log(`✅ Passed: sub "${c.subreddit}" bypassed validation (status: ${res.status})`);
        } else {
            console.log(`❌ Failed: sub "${c.subreddit}" returned status ${res.status}`);
            failures++;
        }
    }

    console.log(`\n🎉 Testing complete. Failures: ${failures}`);
    process.exit(failures > 0 ? 1 : 0);
}

runTests().catch(err => {
    console.error('Test Execution Error:', err);
    process.exit(1);
});
