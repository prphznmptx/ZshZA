-- ============================================================================
-- COMPLETE PROPOSAL & NEGOTIATION WORKFLOW - Database Triggers & Functions
-- ============================================================================
-- This SQL fixes the critical gaps in the proposal workflow:
-- 1. Notify providers when manager accepts/declines/counter-proposes
-- 2. Create todo when proposal is accepted
-- 3. Support negotiation workflow with proper status tracking
-- ============================================================================

-- ============================================================================
-- 1. UPDATED TRIGGER: Notify provider on proposal status change
-- ============================================================================

CREATE OR REPLACE FUNCTION notify_provider_on_proposal_update()
RETURNS TRIGGER AS $$
BEGIN
  -- Only notify if status actually changed
  IF NEW.status != OLD.status THEN
    INSERT INTO public.notifications (user_id, task_id, type, message)
    SELECT 
      up.user_id,
      NEW.task_id,
      CASE 
        WHEN NEW.status = 'accepted' THEN 'proposal_accepted'::character varying
        WHEN NEW.status = 'declined' THEN 'proposal_declined'::character varying
        WHEN NEW.status = 'counter_proposed' THEN 'proposal_updated'::character varying
        ELSE 'task_updated'::character varying
      END,
      CASE
        WHEN NEW.status = 'accepted' THEN 'Your proposal has been ACCEPTED! Check your Todo List for the task.'
        WHEN NEW.status = 'declined' THEN 'Your proposal has been declined. You can submit a new proposal or chat with the manager.'
        WHEN NEW.status = 'counter_proposed' THEN 'Manager has sent a counter-proposal. Review it and respond or chat to negotiate.'
        ELSE 'Proposal status updated'
      END
    FROM user_profiles up
    WHERE up.id = NEW.provider_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Recreate the trigger
DROP TRIGGER IF EXISTS on_proposal_update ON public.task_proposals;
CREATE TRIGGER on_proposal_update
  AFTER UPDATE ON public.task_proposals
  FOR EACH ROW
  EXECUTE FUNCTION notify_provider_on_proposal_update();

-- ============================================================================
-- 2. NEW TRIGGER: Create todo when proposal is accepted
-- ============================================================================

CREATE OR REPLACE FUNCTION create_todo_on_proposal_acceptance()
RETURNS TRIGGER AS $$
BEGIN
  -- Create a todo list entry when proposal is accepted
  IF NEW.status = 'accepted' AND OLD.status != 'accepted' THEN
    INSERT INTO public.todo_list (
      task_id,
      provider_id,
      title,
      description,
      priority,
      due_date,
      details,
      status
    )
    SELECT
      t.id,
      NEW.provider_id,
      t.title,
      t.description,
      t.priority,
      t.due_date,
      jsonb_build_object(
        'category', t.category,
        'estimated_time', t.estimated_time,
        'payment_terms', t.payment_terms,
        'budget', t.budget,
        'agreed_price', NEW.quoted_price,
        'agreed_timeline', NEW.proposed_timeline,
        'proposal_notes', NEW.proposal_notes
      ),
      'pending'::character varying
    FROM tasks t
    WHERE t.id = NEW.task_id
    ON CONFLICT DO NOTHING;

    -- Notify provider that todo has been created with agreed terms
    INSERT INTO public.notifications (user_id, task_id, type, message)
    SELECT 
      up.user_id,
      NEW.task_id,
      'todo_created'::character varying,
      'Your proposal has been accepted! A todo has been created with the agreed terms.'
    FROM user_profiles up
    WHERE up.id = NEW.provider_id;

    -- Notify manager that they accepted and todo is created
    INSERT INTO public.notifications (user_id, task_id, type, message)
    SELECT 
      NEW.manager_id,
      NEW.task_id,
      'task_updated'::character varying,
      'Proposal accepted. Task moved to provider todo list.'
    WHERE NEW.manager_id IS NOT NULL;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create the trigger for proposal acceptance -> todo creation
DROP TRIGGER IF EXISTS on_proposal_acceptance_create_todo ON public.task_proposals;
CREATE TRIGGER on_proposal_acceptance_create_todo
  AFTER UPDATE ON public.task_proposals
  FOR EACH ROW
  EXECUTE FUNCTION create_todo_on_proposal_acceptance();

-- ============================================================================
-- 3. UPDATED TRIGGER: Create todo when task is directly accepted (no proposal)
-- ============================================================================

CREATE OR REPLACE FUNCTION create_todo_on_task_acceptance()
RETURNS TRIGGER AS $$
BEGIN
  -- Create a todo list entry when task is accepted directly (no proposal)
  IF NEW.action = 'accept' THEN
    INSERT INTO public.todo_list (
      task_id,
      provider_id,
      title,
      description,
      priority,
      due_date,
      details,
      status
    )
    SELECT
      t.id,
      NEW.provider_id,
      t.title,
      t.description,
      t.priority,
      t.due_date,
      jsonb_build_object(
        'category', t.category,
        'estimated_time', t.estimated_time,
        'payment_terms', t.payment_terms,
        'budget', t.budget
      ),
      'pending'::character varying
    FROM tasks t
    WHERE t.id = NEW.task_id
    ON CONFLICT DO NOTHING;

    -- Notify the provider that a todo has been created
    INSERT INTO public.notifications (user_id, task_id, type, message)
    SELECT 
      up.user_id,
      NEW.task_id,
      'todo_created'::character varying,
      'You have accepted the task! A todo has been created in your Todo List.'
    FROM user_profiles up
    WHERE up.id = NEW.provider_id;

    -- Notify manager that provider accepted
    INSERT INTO public.notifications (user_id, task_id, type, message)
    SELECT 
      t.created_by,
      NEW.task_id,
      'task_accepted'::character varying,
      'Provider has accepted your task. It is now in their Todo List.'
    FROM tasks t
    WHERE t.id = NEW.task_id;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Recreate the trigger
DROP TRIGGER IF EXISTS on_task_acceptance_create_todo ON public.task_responses;
CREATE TRIGGER on_task_acceptance_create_todo
  AFTER INSERT ON public.task_responses
  FOR EACH ROW
  EXECUTE FUNCTION create_todo_on_task_acceptance();

-- ============================================================================
-- 4. NEW TABLE: Task Negotiation Status (to track proposal/negotiation state)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.task_negotiation_status (
  id uuid NOT NULL DEFAULT extensions.uuid_generate_v4(),
  task_id uuid NOT NULL UNIQUE,
  status character varying(50) NOT NULL DEFAULT 'pending'::character varying,
  -- pending: waiting for initial response
  -- proposing: provider proposed, manager reviewing
  -- negotiating: counter-proposals happening
  -- agreed: terms agreed, todo should be created
  -- concluded: todo created, negotiation complete
  current_proposal_id uuid NULL,
  final_price numeric(12, 2) NULL,
  final_timeline varchar(100) NULL,
  final_notes text NULL,
  created_at timestamp with time zone NULL DEFAULT now(),
  updated_at timestamp with time zone NULL DEFAULT now(),
  
  CONSTRAINT task_negotiation_status_pkey PRIMARY KEY (id),
  CONSTRAINT task_negotiation_status_task_id_fkey FOREIGN KEY (task_id) 
    REFERENCES tasks (id) ON DELETE CASCADE,
  CONSTRAINT task_negotiation_status_proposal_id_fkey FOREIGN KEY (current_proposal_id) 
    REFERENCES task_proposals (id) ON DELETE SET NULL
) TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_task_negotiation_status_task_id 
  ON public.task_negotiation_status USING btree (task_id) TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_task_negotiation_status_status 
  ON public.task_negotiation_status USING btree (status) TABLESPACE pg_default;

-- ============================================================================
-- 5. NEW FUNCTION: Mark negotiation as complete and create todo from final terms
-- ============================================================================

CREATE OR REPLACE FUNCTION conclude_negotiation(
  task_id_param uuid,
  provider_id_param uuid,
  final_price_param numeric DEFAULT NULL,
  final_timeline_param varchar DEFAULT NULL,
  final_notes_param text DEFAULT NULL
)
RETURNS void AS $$
DECLARE
  v_task_record tasks%ROWTYPE;
  v_proposal_record task_proposals%ROWTYPE;
BEGIN
  -- Get the task
  SELECT * INTO v_task_record FROM tasks WHERE id = task_id_param;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found: %', task_id_param;
  END IF;

  -- Get the latest proposal for this task
  SELECT * INTO v_proposal_record FROM task_proposals 
  WHERE task_id = task_id_param AND provider_id = provider_id_param
  ORDER BY created_at DESC LIMIT 1;

  -- Create or update the negotiation status
  INSERT INTO public.task_negotiation_status (task_id, status, final_price, final_timeline, final_notes)
  VALUES (task_id_param, 'agreed', final_price_param, final_timeline_param, final_notes_param)
  ON CONFLICT (task_id) DO UPDATE SET
    status = 'agreed',
    final_price = final_price_param,
    final_timeline = final_timeline_param,
    final_notes = final_notes_param,
    updated_at = now();

  -- Create todo with agreed terms
  INSERT INTO public.todo_list (
    task_id,
    provider_id,
    title,
    description,
    priority,
    due_date,
    details,
    status
  )
  VALUES (
    task_id_param,
    provider_id_param,
    v_task_record.title,
    v_task_record.description,
    v_task_record.priority,
    v_task_record.due_date,
    jsonb_build_object(
      'category', v_task_record.category,
      'estimated_time', v_task_record.estimated_time,
      'payment_terms', v_task_record.payment_terms,
      'budget', v_task_record.budget,
      'agreed_price', COALESCE(final_price_param, v_proposal_record.quoted_price, v_task_record.budget),
      'agreed_timeline', COALESCE(final_timeline_param, v_proposal_record.proposed_timeline, v_task_record.estimated_time),
      'final_notes', final_notes_param
    ),
    'pending'::character varying
  )
  ON CONFLICT DO NOTHING;

  -- Notify provider that negotiation is complete
  INSERT INTO public.notifications (user_id, task_id, type, message)
  SELECT 
    up.user_id,
    task_id_param,
    'todo_created'::character varying,
    'Negotiation complete! A todo has been created with the final agreed terms.'
  FROM user_profiles up
  WHERE up.id = provider_id_param;

  -- Update negotiation status to concluded
  UPDATE public.task_negotiation_status 
  SET status = 'concluded', updated_at = now()
  WHERE task_id = task_id_param;

END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 6. GRANT PERMISSIONS
-- ============================================================================

-- Allow service providers to call the conclude_negotiation function
-- GRANT EXECUTE ON FUNCTION conclude_negotiation(uuid, uuid, numeric, varchar, text) TO authenticated;
