# Project decisions

| Topic | Current decision | Status |
|---|---|---|
| Business | MJ Printing & Branding, one physical shop | Confirmed |
| First release | Complete owner-first version covering website, enquiries, customers, quotes, orders, payments, inventory, purchasing/receiving, production, QC, job costing, expenses, delivery and reporting | Confirmed |
| Frontend | React + TypeScript + Vite | Confirmed |
| Hosting | GitHub Pages for now | Confirmed |
| Backend | Existing Supabase project rbbluwsniiwzixlvdnwz | Confirmed |
| Website and system | Build together in one application | Confirmed |
| Shared device | Individual staff accounts; no shared credentials | Confirmed |
| Domain | Purchase and connect later | Deferred |
| Payments | Cash and M-Pesa Paybill recording and reconciliation initially | Confirmed |
| Payment plans | Deposits and instalments; maintain payment allocations and balances | Confirmed |
| Collection | Full payment before handover; owner-approved exception must be recorded | Confirmed |
| Stock model | Keep selected items; purchase shortages after order; track variants, measured materials, stock movements and job issues/waste/returns | Confirmed |
| Artwork files | Stored in Google Drive; application stores references, approvals and version history | Confirmed |
| Product sale modes | Products may be sold blank or value-added; customer-supplied items are supported | Confirmed |
| Production costing | Separate costing profiles for vinyl/stickers, sublimation, screen printing, no-cut printing and outsourced processes | Confirmed |
| Meter material costing | Vinyl bought by metre is costed from roll width, cut dimensions, yield, actual consumption, waste and reusable offcuts | Confirmed |
| Job profitability | Track estimated vs actual direct cost and gross profit by line/order/category/process; overhead and delivery are separate | Confirmed |
| Staff | Owner-first workflows; staff permissions can be expanded as needed | Confirmed |
| Brand identity | Orange, blue and green MJ Printing & Branding identity | Confirmed |
| Database schema | Design and review before implementation | Required |
| Database migration | Requires separate explicit approval | Required |
| Production deployment | Not included in repository-file approval | Not approved |

Update this record when a decision is explicitly confirmed. Distinguish confirmed decisions from recommendations and unresolved questions.
