# Customer Management & Loyalty

## Customer directory
The owner workspace supports individuals, schools, uniform shops, businesses, other organisations, chamas, SHGs, CBOs and walk-in customers. Profiles include contact details, location, registration reference, preferred contact channel, status and notes. Existing customer IDs remain the common link for quotations, orders, payments and delivery history.

Anonymous walk-in sales use one protected shared Walk-in customer profile. No name, phone or email is forced for a counter sale. If the buyer identifies themselves, select or create their own profile instead. Walk-in profile is protected from ordinary profile edits.

## Contacts and addresses
An organisation can have multiple contact people (e.g. proprietor, manager, bursar, procurement officer, chairperson, secretary or treasurer). Each contact can be marked primary and assigned operational permissions: place orders, approve quotations, collect orders. These are CRM notes, not login permissions.

Multiple delivery addresses are stored in the existing `customer_addresses` table and are linked to the customer. Addresses can include label, recipient, phone, locality and default destination.

## Customer history
The profile brings together linked quotations and orders, plus a separate interaction timeline for calls, WhatsApp, email, meetings, follow-ups, complaints and service notes. Existing payments, receipts, refunds and delivery history continue to use their existing ledgers and workflows. Customer-supplied items remain recorded on order lines through the existing `customer_supplies_item` field.

## Rewards and bonuses
Rules can be defined for all customers or an individual category: returning customer, order value/volume, referral, group volume, seasonal promotion or manual reward. Rules specify reward kind (points, credit or discount), fixed or per-KSh-100 calculation, minimum order value/count, and eligible products/services (all, printing, products, blanks). New rules default to disabled; activation is an explicit owner choice.

Every reward action is recorded in `customer_reward_ledger`: earned, manual bonus, redeemed, reversed or expired. The ledger stores amount, reason, actor, optional order/rule and reversal reference. Balances are calculated from ledger entries. Reward credits/discounts/points are not customer payments, cash receipts, refunds or expenses. Manual rewards require an owner action and reason and are audited. Do not use a reward to alter order value or payment allocation.

**Automation boundary:** this release provides configurable rules and an auditable owner-operated reward ledger. It does not yet automatically evaluate rules on order completion or automatically redeem credits at checkout. The owner must review eligibility and post the reward; this prevents duplicate awards on amended orders or instalment payments until the automatic event rules are fully tested.

## Security and integrity
All new customer tables have RLS and owner-scoped read policies. Browser clients have no direct insert/update/delete privileges for contacts, interactions, loyalty rules or reward ledger. Mutations go through owner-asserting, idempotent RPCs with audit events. Existing customer/order/payment ledgers are reused; this feature creates no duplicate financial ledgers.

## Owner workflow
1. Add or search for the customer.
2. Add organisation contacts and one or more delivery addresses.
3. Record calls, messages, follow-ups, complaints and resolutions.
4. Review quotation and order history.
5. Configure category-specific loyalty rules; leave disabled until approved.
6. Post an earned reward, bonus, redemption or correction with a reason. Review the resulting ledger balance.

## Out of scope
Customer portal/login, staff CRM permissions, automatic WhatsApp/email messaging, automatic loyalty evaluation/redemption, and reward conversion into cash are not enabled.
