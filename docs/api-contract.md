# НарядAI — shared implementation contract

React/TypeScript/Vite frontend; FastAPI/SQLAlchemy backend; PostgreSQL via Docker Compose. SQLite is allowed only for local development and tests. Russian UI. UTC ISO timestamps; UI Asia/Almaty. API base `/api`. Auth Bearer token returned by POST `/auth/login` {login,pin}; response {token,user}. GET `/auth/me` user. Roles master,worker,manager,admin. Demo accounts master / worker / manager / admin PIN 1234; second master master2 and workers worker2…worker15.

Status codes: issued,accepted,queued,rejected,in_progress,paused,completed,ai_review,rework,closed,cancelled. Priority emergency,high,normal,planned. Work type planned,unplanned. Each transition audited. Overdue is a derived flag, not status.

GET `/reference` -> {areas:[{id,name}],equipment:[{id,name,inventory_number,area_id,type,criticality}],employees:[{id,name,login,role,specialty,grade,brigade_id,on_shift}],brigades:[{id,name}],fault_codes:[{id,code,name}],materials:[{id,name,unit}],time_norms:[{id,name,hours}]}. Admin POST/PATCH `/reference/{collection}` (PATCH /{id}) with object fields. No delete needed.

GET `/employees` -> array reference employee fields + {status:free|busy|queued|off_shift,current_order:string|null,queue_count:number,rating:number,completed_count:number}.

GET `/orders` query area_id,equipment_id,assignee_id,brigade_id,priority,status,search,from_date,to_date,limit (default 1000) -> array Order. GET `/orders/{id}` -> OrderDetail. GET `/dashboard` -> {issued,completed,overdue,downtime_count,active,total,avg_rating,shift_label}. Shift metrics use local current shift; list may include historical closed orders.

Order: {id,number,title,description,work_type,area_id,area_name,equipment_id,equipment_name,assignee_id,assignee_name,brigade_id,master_id,priority,status,deadline,created_at,started_at,completed_at,closed_at,comment,is_overdue,normal_hours,downtime_minutes,score}. Detail extends {events:[{id,action,from_status,to_status,actor_name,created_at,comment}],photos:[{id,kind,url,created_at,author_name}],completion:{work_done,fault_code_id,comment,materials:[{material_id,name,quantity,unit}]}|null,ai_review:{verdict,score,explanation,is_stub,master_score}|null}.

POST `/orders` {title,description,work_type,area_id,equipment_id,assignee_id?,brigade_id?,priority,deadline,normal_hours?,comment?} -> detail. Exactly one assignee or brigade, brigade resolved to available lead for demo but retains brigade_id. PATCH `/orders/{id}` {assignee_id?,brigade_id?,priority?,deadline?,comment?}; all edits audited.

POST `/orders/{id}/transition` {action,reason?,comment?,score?}. Actions accept,queue,reject,start,pause,resume,close,rework,cancel. Worker only assigned orders; master/admin can manage. Manager read-only. Reasons required reject/pause/rework/cancel. close only after ai_review, master final decision.

POST `/orders/{id}/complete` {work_done,fault_code_id,materials:[{material_id,quantity}],comment?} -> detail. Only in_progress. Validate unplanned after photo exists (422 otherwise); master/worker upload before completing. Records completed then ai_review events; deterministic stub verdict with explicit is_stub=true, manual master acceptance mandatory.

POST `/orders/{id}/photos` multipart `file`, `kind` before|after -> photo. Pillow validation, compressed JPEG, max 10MB, max 5 per kind. Photos served GET `/photos/{id}` with Bearer auth; frontend fetch to Blob URL (not public uploads).

GET `/notifications` -> [{id,title,message,kind,order_id,created_at,read}]. POST `/notifications/{id}/read`. Deadline background monitor every <=5sec, deduplicated due-soon/overdue/unaccepted notifications persisted for worker and master. Native push adapter logs/persists only, never real push.

GET `/analytics` query days (default 90),from_date,to_date,area_id,equipment_id,assignee_id,brigade_id -> {summary:{total,closed,on_time_percent,avg_score,downtime_hours},trend:[{date,planned,unplanned}],by_area:[{name,count,downtime_hours}],rankings:[{id,name,specialty,brigade,score,quality,on_time,closed_count,rework_rate}],equipment:[{id,name,area_name,orders,downtime_hours}],materials:[{name,unit,quantity}],insights:[{title,description,severity,is_stub}],ai_summary:string,is_stub:true}. Ratings computed deterministically, formula documented.

GET `/reports/export` same filters as analytics, `format=csv|xlsx` -> real CSV (UTF-8 BOM) or XLSX with order and summary worksheets; spreadsheet-safe strings. POST `/auth/logout` revokes the current session. Native + AI interfaces GET `/integrations` -> {ai:{mode,status,description},native:{mode,status,description},realtime:{mode,status,description}}. GET `/health` public.

Realtime: authenticated WebSocket `/api/ws?token=…` (alias `/ws?token=…`), event {type:'orders.updated'|'notifications.updated'|'connected',order_id?}; clients refetch; 5-second polling fallback. No personal data in broadcast. Tokens revalidated at least every 30 seconds even on idle connections.

Directories: backend/ owned backend agent; frontend/ owned frontend agent; infrastructure/docs/native-stub owned infra agent. Root coordinates dependencies and integration tests. Seed at least 520 historical orders over 90 days plus active current-shift orders, 4 areas,25 equipment,2 masters,15 workers,3 brigades,20 fault codes,40 materials. Embed repeated conveyor faults, recurring post-maintenance issue, high material consumption. Stub insights clearly labeled. No external services or real employee data.
