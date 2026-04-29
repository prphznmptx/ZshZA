# Negotiation Chat Feature - Complete Schema & Implementation Guide

## Overview

The negotiation chat feature enables service providers and managers to discuss and finalize task terms through real-time chat. This document details the Supabase schema requirements, data flow, and critical implementation notes.

---

## Schema Summary

### Reused Tables (No Changes Required)

#### 1. **task_proposals**
Stores proposal data between manager and service provider.

```sql
Table: task_proposals
├── id (UUID, PK)
├── task_id (FK → tasks)
├── provider_id (FK → user_profiles) ⚠️ IMPORTANT: user_profiles, NOT auth.users
├── manager_id (FK → auth.users)
├── status: 'pending' | 'accepted' | 'declined' | 'counter_proposed'
├── quoted_price (NUMERIC 12,2)
├── proposal_notes (TEXT)
├── proposed_timeline (VARCHAR 100)
├── attachments (JSONB array)
├── created_at, updated_at (TIMESTAMP)
```

**Usage in Negotiation:**
- Tracks the initial proposal and any counter-proposals
- Status changes to 'accepted' when negotiation is finalized
- Stores agreed terms (price, timeline, notes)

---

#### 2. **task_messages**
Real-time chat messages during negotiation.

```sql
Table: task_messages
├── id (UUID, PK)
├── task_id (FK → tasks)
├── sender_id (FK → auth.users)
├── sender_role: 'manager' | 'service_provider'
├── message_text (TEXT)
├── attachments (JSONB array) [DEPRECATED - use task_message_attachments instead]
├── is_read (BOOLEAN)
├── created_at, updated_at (TIMESTAMP)
```

**Usage in Negotiation:**
- Stores conversation between manager and service provider
- Attachments JSONB field deprecated (use junction table instead)
- is_read flag for notification management

---

#### 3. **todo_list**
Final agreed tasks after negotiation is complete.

```sql
Table: todo_list
├── id (UUID, PK)
├── task_id (FK → tasks)
├── provider_id (FK → user_profiles) ⚠️ CRITICAL: Must be user_profiles.id
├── status: 'pending' | 'in_progress' | 'completed'
├── title (VARCHAR 255)
├── description (TEXT)
├── priority: 'low' | 'medium' | 'high' | 'urgent'
├── due_date (DATE)
├── estimated_hours (NUMERIC 5,2)
├── details (JSONB) ← Stores negotiation results
│   ├── category (STRING)
│   ├── estimated_time (STRING)
│   ├── payment_terms (STRING)
│   ├── budget (NUMBER) ← Final agreed price
│   ├── timeline (STRING) ← Final agreed timeline
│   └── negotiation_notes (STRING) ← Final agreed notes
├── attachments (JSONB array)
├── created_at, completed_at, updated_at (TIMESTAMP)
```

**Usage in Negotiation:**
- Created when proposal is finalized
- **CRITICAL**: provider_id MUST come from user_profiles.id, NOT auth.users.id
- details.budget, details.timeline, details.negotiation_notes store final terms

---

#### 4. **task_negotiation_status**
Tracks negotiation lifecycle and final terms.

```sql
Table: task_negotiation_status
├── id (UUID, PK)
├── task_id (FK → tasks, UNIQUE)
├── status: 'pending' | 'negotiating' | 'finalized' | 'failed'
├── current_proposal_id (FK → task_proposals)
├── final_price (NUMERIC 12,2)
├── final_timeline (VARCHAR 100)
├── final_notes (TEXT)
├── created_at, updated_at (TIMESTAMP)
```

**Usage in Negotiation:**
- Optional tracking of negotiation state
- Updated automatically when proposal is accepted (via trigger)
- Provides audit trail of final agreed terms

---

### New Table (NEW - Must Be Created)

#### 5. **task_message_attachments** ✨ NEW
Junction table linking messages to file attachments (similar pattern to complaint_attachments and task_attachments).

```sql
Table: task_message_attachments
├── id (UUID, PK)
├── message_id (FK → task_messages)
├── attachment_id (FK → attachments)
├── created_at (TIMESTAMP)
├── UNIQUE(message_id, attachment_id)
```

**Purpose:**
- Links attachments to specific messages
- Follows existing pattern used in complaint_attachments and task_attachments
- Maintains referential integrity
- Allows multiple attachments per message

**SQL Migration:**
```sql
CREATE TABLE IF NOT EXISTS public.task_message_attachments (
  id UUID NOT NULL DEFAULT gen_random_uuid(),
  message_id UUID NOT NULL,
  attachment_id UUID NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  
  CONSTRAINT task_message_attachments_pkey PRIMARY KEY (id),
  CONSTRAINT task_message_attachments_unique UNIQUE (message_id, attachment_id),
  CONSTRAINT task_message_attachments_message_id_fkey 
    FOREIGN KEY (message_id) REFERENCES task_messages (id) ON DELETE CASCADE,
  CONSTRAINT task_message_attachments_attachment_id_fkey 
    FOREIGN KEY (attachment_id) REFERENCES attachments (id) ON DELETE CASCADE
) TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_task_message_attachments_message_id 
  ON public.task_message_attachments USING btree (message_id);

CREATE INDEX IF NOT EXISTS idx_task_message_attachments_attachment_id 
  ON public.task_message_attachments USING btree (attachment_id);
```

---

## Critical Implementation Details

### ⚠️ CRITICAL: provider_id Foreign Key Constraint

**Problem:** The todo_list table has a foreign key constraint on provider_id that references user_profiles.id, NOT auth.users.id.

**Error You'll Get if Done Wrong:**
```
409 {"code":"23503","details":"Key is not present in table \"user_profiles\".","message":"insert or update on table \"todo_list\" violates foreign key constraint \"todo_list_provider_id_fkey\""}
```

**Solution:**
When creating a todo from negotiation, use the correct ID:

```typescript
// ❌ WRONG - Will cause FK constraint violation
provider_id: currentUser?.id  // This is auth.users.id

// ✅ CORRECT
provider_id: currentUserProfile?.id  // This is user_profiles.id
```

**Code Fix Applied:**
In `NegotiationChat.tsx`:
```typescript
const providerId = currentUserRole === "service_provider" 
  ? currentUserProfileId  // user_profiles.id ✅
  : initialProposal.provider_id; // user_profiles.id from proposal ✅

const { error: todoError } = await supabase
  .from("todo_list")
  .insert([
    {
      task_id: taskId,
      provider_id: providerId, // MUST be user_profiles.id
      // ... rest of data
    },
  ]);
```

---

## Data Flow: From Proposal to Task

### Step 1: Manager Creates Task & Sends Initial Proposal
```
Manager → Creates Task → Sends proposal with quoted_price, proposed_timeline
         ↓
    task_proposals
    ├── status: 'pending'
    ├── quoted_price: 100.00
    ├── proposed_timeline: '5 days'
    └── proposal_notes: 'Please confirm...'
```

### Step 2: Service Provider Opens Negotiation Chat
```
Service Provider → Clicks "Open Chat" button
                 ↓
            NegotiationChat component opens
            ├── Shows initial terms
            ├── Allows editing price, timeline, notes
            └── Enables file/voice uploads
```

### Step 3: Back-and-Forth Messages
```
Service Provider sends message with attachments
                 ↓
            task_messages row created
            ├── message_id → message text
            └── attachments (via task_message_attachments)
                 ↓
Manager receives notification & responds similarly
```

### Step 4: Service Provider Finalizes
```
Service Provider clicks "Finalize & Accept"
                 ↓
        handleFinalizeNegotiation() called
                 ↓
    1. Update task_proposals.status → 'accepted'
    2. Update final terms (price, timeline, notes)
    3. Create todo_list entry with agreed terms
    4. Trigger: Update task_negotiation_status
                 ↓
Service Provider sees task in "Your Accepted Tasks"
```

### Final Data State
```
task_proposals
├── id: proposal-uuid
├── status: 'accepted'
├── quoted_price: 125.00 (negotiated)
└── proposed_timeline: '7 days' (negotiated)
    ↓
todo_list (created by trigger/manual)
├── provider_id: user-profile-uuid ✅
├── details.budget: 125.00
├── details.timeline: '7 days'
└── details.negotiation_notes: 'Final notes...'
    ↓
task_negotiation_status (auto-updated)
├── status: 'finalized'
├── final_price: 125.00
├── final_timeline: '7 days'
└── final_notes: 'Final notes...'
```

---

## Database Trigger for Auto-Updates

The migration includes a trigger to automatically update task_negotiation_status when a proposal is accepted:

```sql
CREATE TRIGGER on_proposal_finalized_update_status
AFTER UPDATE OF status ON public.task_proposals
FOR EACH ROW
WHEN (NEW.status = 'accepted')
EXECUTE FUNCTION public.on_proposal_finalized();
```

This ensures that whenever `task_proposals.status` changes to 'accepted', the `task_negotiation_status` table is automatically updated with the final terms.

---

## Component Props Reference

### NegotiationChat Component
```typescript
interface NegotiationChatProps {
  proposalId: string;                    // task_proposals.id
  taskId: string;                        // tasks.id
  currentUserId: string;                 // auth.users.id
  currentUserProfileId: string;          // user_profiles.id ⚠️ REQUIRED
  currentUserRole: "manager" | "service_provider";
  otherPartyName: string;
  initialProposal: TaskProposal;
  task: Task;
  onNegotiationFinalized?: () => void;
}
```

### ServiceProviderProposalReview Component
```typescript
interface ServiceProviderProposalReviewProps {
  proposal: TaskProposal | null;
  taskTitle: string;
  managerName: string;
  task?: Task;
  currentUserId?: string;                // auth.users.id
  currentUserProfileId?: string;         // user_profiles.id ⚠️ REQUIRED
  onProposalUpdated?: () => void;
}
```

---

## File Upload Integration

The negotiation chat reuses existing file upload infrastructure:

### 1. Attachment Storage
Files are uploaded to Backblaze B2 and tracked in the `attachments` table:
```sql
attachments
├── id (UUID)
├── user_id (FK → auth.users) - who uploaded
├── filename, original_name
├── file_size, mime_type
├── b2_url, b2_file_id
├── file_type: 'image' | 'video' | 'file' | 'audio'
└── is_public
```

### 2. Message Attachment Linking
For negotiation messages, attachments are linked via the new junction table:
```sql
task_message_attachments
├── message_id (FK → task_messages)
├── attachment_id (FK → attachments)
└── created_at
```

### 3. Code Integration
```typescript
// Upload file
const uploadedFiles = await uploadMultipleFiles(files, 'negotiations');

// Link to message
const { error } = await supabase
  .from("task_messages")
  .insert([
    {
      message_id: messageId,
      attachments: uploadedFiles.map(f => ({
        id: f.attachmentId,
        name: f.originalName,
        size: f.fileSize,
      }))
    }
  ]);

// Also link via junction table (recommended)
const attachmentLinks = uploadedFiles.map(f => ({
  message_id: messageId,
  attachment_id: f.attachmentId,
}));
await supabase
  .from("task_message_attachments")
  .insert(attachmentLinks);
```

---

## Voice Notes Integration

Voice recordings are handled via the existing `VoiceRecorder` component:

1. **Record:** Browser MediaRecorder API (reuses useVoiceRecording hook)
2. **Upload:** Converts to MP3 → uploads via useFileUpload
3. **Store:** Attachment record created with file_type: 'audio'
4. **Link:** Added as attachment to message

---

## Migration Checklist

- [ ] Run the migration SQL from `supabase/migrations/negotiation_chat_schema.sql`
- [ ] Create `task_message_attachments` table
- [ ] Verify indexes are created
- [ ] Test foreign key constraints (provider_id must be user_profiles.id)
- [ ] Verify trigger `on_proposal_finalized_update_status` is created
- [ ] Verify view `negotiation_threads` is available (optional, for analytics)
- [ ] Update RLS policies if using Row Level Security

---

## Supabase Setup Steps

1. **Connect to Supabase Dashboard**
   - Go to https://supabase.com/dashboard
   - Select your project
   - Go to SQL Editor

2. **Run Migration**
   - Click "New Query"
   - Copy contents of `supabase/migrations/negotiation_chat_schema.sql`
   - Execute the query
   - Verify no errors

3. **Verify Schema**
   - Go to Table Editor
   - Confirm `task_message_attachments` table exists
   - Confirm foreign keys on `todo_list.provider_id` references `user_profiles.id`

4. **Test the Feature**
   - Create a task as manager
   - Send proposal to service provider
   - Service provider clicks "Open Chat"
   - Send messages with attachments
   - Click "Finalize & Accept"
   - Verify todo is created in "Your Accepted Tasks"

---

## Troubleshooting

### Error: "Key is not present in table 'user_profiles'"
**Cause:** Using auth.users.id instead of user_profiles.id for provider_id

**Fix:** 
```typescript
// Wrong
provider_id: currentUser?.id

// Correct
provider_id: currentUserProfile?.id
```

### Error: "Column 'current_proposal_id' is not unique"
**Cause:** Multiple proposals trying to update same task's negotiation status

**Fix:** The trigger uses `ON CONFLICT (task_id)` to handle this - should be automatic

### Messages don't show up in chat
**Cause:** Supabase realtime subscription not working

**Fix:**
```typescript
// Ensure realtime is enabled on task_messages table
supabase
  .channel(`negotiation:${proposalId}`)
  .on('postgres_changes', {
    event: 'INSERT',
    schema: 'public',
    table: 'task_messages',
    filter: `task_id=eq.${taskId}`,
  }, callback)
  .subscribe();
```

### Attachments not showing in messages
**Cause:** Not using task_message_attachments junction table

**Fix:**
```typescript
// Link attachments properly
const attachmentLinks = uploadedFiles.map(f => ({
  message_id: messageId,
  attachment_id: f.attachmentId,
}));
await supabase
  .from("task_message_attachments")
  .insert(attachmentLinks);
```

---

## Performance Considerations

### Indexes to Monitor
- `idx_task_messages_task_id_created_at` - For chat history
- `idx_task_proposals_status_active` - For active negotiations
- `idx_task_message_attachments_message_id` - For message attachments

### Query Optimization
When loading negotiation thread:
```typescript
// Get messages with attachments efficiently
const messages = await supabase
  .from('task_messages')
  .select(`
    *,
    task_message_attachments(*)
  `)
  .eq('task_id', taskId)
  .order('created_at', { ascending: true });
```

---

## Security & RLS

The migration includes RLS policies:
- Users can only view messages for negotiations they're involved in
- Service providers can only view their own negotiation threads
- Managers can view negotiations for their assigned tasks

Ensure RLS is enabled on:
- task_messages
- task_message_attachments
- task_proposals

---

## Summary

| Aspect | Details |
|--------|---------|
| **New Tables** | task_message_attachments |
| **Modified Tables** | None (all existing tables reused) |
| **Key Field** | todo_list.provider_id (must be user_profiles.id) |
| **Reused Infrastructure** | attachments, task_messages, task_proposals, todo_list |
| **File Types Supported** | images, videos, audio (voice notes), documents |
| **Triggers Created** | on_proposal_finalized_update_status |
| **Views Created** | negotiation_threads (optional analytics) |
| **Components Updated** | NegotiationChat, ServiceProviderProposalReview, TasksPage |

---

## Next Steps

1. Run the SQL migration in Supabase
2. Test the negotiation chat feature end-to-end
3. Monitor error logs for FK constraint issues
4. Set up monitoring for negotiation completion rates
5. Implement manager-side negotiation chat (similar pattern)
