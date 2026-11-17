# First-owner provisioning — MJ Tees

**Purpose:** provision exactly one owner after the schema and transactional backend have been reviewed and separately approved for hosted database execution.

## Before running

1. The intended owner creates an Auth account using the agreed email sign-in method.
2. An authorised operator verifies the owner's identity out of band.
3. The operator confirms the exact Auth user UUID from the Supabase Auth user record.
4. The operator obtains their own identified Auth user UUID for the audit record.
5. The operator prepares the values for `scripts/bootstrap-first-owner.sql`.

The script is a trusted administrative operation. Run it only through a protected psql session or another trusted database administration environment. Never run it from the public website or browser.

## Values

- Business name: MJ Printing & Branding
- Trading name: MJ Tees
- Slug: `mj-tees` (confirm before the first run)
- Currency: KES
- Time zone: Africa/Nairobi
- Owner: the verified Auth user UUID
- Operator: the identified provisioning operator Auth user UUID
- Reason: a short, factual explanation of the identity verification and approval

## Safeguards in the script

- Confirms both Auth users exist.
- Takes a transaction-scoped advisory lock so concurrent bootstrap operators serialize before checking or writing.
- Refuses to run if an active owner already exists.
- Refuses to run if a completed bootstrap record exists.
- Creates the business, profile, exactly one active owner membership, bootstrap completion record, document counters and audit event in one transaction.
- A unique business slug and membership key provide additional duplicate protection.
- No owner is selected based on signup order, email domain, user metadata or a browser-supplied role.

## After provisioning

1. Sign in as the owner using a normal Auth session.
2. Verify the owner can read only the provisioned business.
3. Verify a separate authenticated user cannot read business records or execute owner RPCs.
4. Confirm the bootstrap record is completed and the audit event exists.
5. Do not retain a reusable service-role credential in source control, GitHub Pages or browser code.

**Not performed:** this script has not been run. No owner account or business has been created in the linked Supabase project.
