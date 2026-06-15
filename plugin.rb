# frozen_string_literal: true
# name: discourse-calendar-rsvp-posts
# about: Create short topic replies for RSVP events
# version: 0.4
# authors: Mario Santana

after_initialize do
  module ::CalendarRsvpPosts
    PLUGIN_NAME = "discourse-calendar-rsvp-posts"
    
    def self.history_marker
      I18n.t('calendar_rsvp_posts.markers.history')
    end
    
    def self.notification_marker
      I18n.t('calendar_rsvp_posts.markers.notification')
    end

    # Helper to decide if we should ignore this event
    def self.should_post_for_event?(event)
      return false if event.nil?
      return true if SiteSetting.calendar_rsvp_posts_allow_past_events
      return false if event.starts_at.nil?
      event.starts_at >= Time.current
    end

    # Find any RSVP post for an event (history or simple notification)
    def self.find_rsvp_posts(event)
      return [] if event.nil? || event.post.nil? || event.post.topic.nil?
      
      event.post.topic.posts
        .where(user_id: Discourse.system_user.id)
        .where("raw LIKE ? OR raw LIKE ?", 
               "%#{history_marker}%",
               "%#{notification_marker}%")
        .order(created_at: :asc)
    end

    # Find the history post specifically
    def self.find_history_post(event)
      return nil if event.nil? || event.post.nil? || event.post.topic.nil?
      
      event.post.topic.posts
        .where(user_id: Discourse.system_user.id)
        .where("raw LIKE ?", "%#{history_marker}%")
        .order(created_at: :asc)
        .first
    end

    # Find and delete all notification posts (but not history post)
    def self.delete_notification_posts(event)
      return if event.nil? || event.post.nil? || event.post.topic.nil?
      
      notification_posts = event.post.topic.posts
        .where(user_id: Discourse.system_user.id)
        .where("raw LIKE ?", "%#{notification_marker}%")
      
      notification_posts.each do |post|
        begin
          PostDestroyer.new(Discourse.system_user, post, context: "calendar-rsvp-posts cleanup").destroy
        rescue StandardError => e
          Rails.logger.warn("calendar-rsvp-posts: failed to delete notification post #{post.id}: #{e}")
        end
      end
    end

    # Build a history entry line with timestamp
    def self.build_history_entry(username, action_label, extra_text = nil)
      timestamp = Time.current.strftime("%Y-%m-%d %H:%M UTC")
      entry = "- **#{timestamp}** - #{username} #{action_label}"
      entry += " (#{extra_text})" if extra_text.present?
      entry
    end

    # Build or update the history post content
    def self.build_history_raw(event, new_entry)
      event_title = (event.name.presence || event.post.topic.title).to_s
      parts = []
      parts << history_marker
      parts << "### #{I18n.t('calendar_rsvp_posts.history.header', event_title: event_title)}"
      parts << ""
      parts << new_entry
      parts.join("\n")
    end

    # Append new entry to existing history
    def self.append_to_history(existing_raw, new_entry)
      # Insert the new entry right after the header (before oldest entries)
      lines = existing_raw.split("\n")
      header_end_idx = lines.index { |line| line.start_with?("### RSVP History") }
      
      if header_end_idx
        # Insert after header and blank line
        insert_idx = header_end_idx + 2
        lines.insert(insert_idx, new_entry)
      else
        # Fallback: just append at the end
        lines << new_entry
      end
      
      lines.join("\n")
    end

    # Convert a simple notification post into history format
    def self.convert_to_history(simple_post, event)
      # Extract info from the simple post
      # Format: <!-- notification marker -->\n**username action** for *event*. [extra]
      raw = simple_post.raw
      
      # Try to parse username and action from the post
      # Build regex pattern with translated action labels
      going_label = I18n.t('calendar_rsvp_posts.actions.going').gsub('(', '\\(').gsub(')', '\\)')
      interested_label = I18n.t('calendar_rsvp_posts.actions.interested').gsub('(', '\\(').gsub(')', '\\)')
      not_going_label = I18n.t('calendar_rsvp_posts.actions.not_going').gsub('(', '\\(').gsub(')', '\\)')
      removed_label = I18n.t('calendar_rsvp_posts.actions.removed').gsub('(', '\\(').gsub(')', '\\)')
      
      pattern = /\*\*([^\*]+)\s+(#{Regexp.escape(going_label)}|#{Regexp.escape(interested_label)}|#{Regexp.escape(not_going_label)}|#{Regexp.escape(removed_label)})\*\*/
      match = raw.match(pattern)
      if match
        username = match[1]
        action = match[2]
        
        # Check for extra text (capacity alerts)
        extra_match = raw.match(/\.\s+([^.]+)\.$/)
        extra_text = extra_match ? extra_match[1] : nil
        
        # Use the post's creation time for the first entry
        timestamp = simple_post.created_at.strftime("%Y-%m-%d %H:%M UTC")
        first_entry = "- **#{timestamp}** - #{username} #{action}"
        first_entry += " (#{extra_text})" if extra_text.present?
        
        # Build history format
        event_title = (event.name.presence || event.post.topic.title).to_s
        parts = []
        parts << history_marker
        parts << "### #{I18n.t('calendar_rsvp_posts.history.header', event_title: event_title)}"
        parts << ""
        parts << first_entry
        parts.join("\n")
      else
        # Couldn't parse, just add history header
        event_title = (event.name.presence || event.post.topic.title).to_s
        history_marker + "\n### #{I18n.t('calendar_rsvp_posts.history.header', event_title: event_title)}\n\n" + raw
      end
    end

    # Build a notification post (simple, short message)
    def self.build_notification_raw(username, action_label, event, extra_text = nil)
      event_title = (event.name.presence || event.post.topic.title).to_s
      extra_text_formatted = extra_text.present? ? "#{extra_text} " : ""
      
      notification_raw = notification_marker + "\n"
      notification_raw += I18n.t('calendar_rsvp_posts.notification.template', 
                                event_title: event_title,
                                extra: extra_text_formatted,
                                username: username,
                                action: action_label)
      notification_raw
    end

    # Central place that creates/revises/deletes the RSVP posts for an event.
    # Wrapped in a per-event mutex so concurrent background jobs for the same
    # event can't race each other and create duplicate posts.
    def self.publish_rsvp_update(event, username, action_label, extra_text = nil)
      DistributedMutex.synchronize("calendar_rsvp_posts_event_#{event.id}") do
        if SiteSetting.calendar_rsvp_posts_enable_history
          # History mode: maintain timestamped history + notification posts
          history_post = find_history_post(event)
          all_rsvp_posts = find_rsvp_posts(event)
          new_entry = build_history_entry(username, action_label, extra_text)

          if all_rsvp_posts.empty?
            # First RSVP: create simple notification post (no history format yet)
            notification_raw = build_notification_raw(username, action_label, event, extra_text)
            PostCreator.create!(
              Discourse.system_user,
              topic_id: event.post.topic_id,
              raw: notification_raw,
              skip_validations: true
            )
          elsif history_post.nil?
            # Second RSVP: convert first post to history format
            first_post = all_rsvp_posts.first
            history_raw = convert_to_history(first_post, event)
            history_raw = append_to_history(history_raw, new_entry)

            # Update the first post to be the history
            revisor = PostRevisor.new(first_post, event.post.topic)
            revisor.revise!(
              Discourse.system_user,
              raw: history_raw,
              skip_validations: true,
              skip_revision: false
            )

            # Create new notification post
            notification_raw = build_notification_raw(username, action_label, event, extra_text)
            PostCreator.create!(
              Discourse.system_user,
              topic_id: event.post.topic_id,
              raw: notification_raw,
              skip_validations: true
            )
          else
            # Third+ RSVP: append to existing history
            updated_raw = append_to_history(history_post.raw, new_entry)
            revisor = PostRevisor.new(history_post, event.post.topic)
            revisor.revise!(
              Discourse.system_user,
              raw: updated_raw,
              skip_validations: true,
              skip_revision: false
            )

            # Delete old notification posts
            delete_notification_posts(event)

            # Create new notification post to trigger notifications
            notification_raw = build_notification_raw(username, action_label, event, extra_text)
            PostCreator.create!(
              Discourse.system_user,
              topic_id: event.post.topic_id,
              raw: notification_raw,
              skip_validations: true
            )
          end
        else
          # No history mode: just delete old posts and create new notification
          all_rsvp_posts = find_rsvp_posts(event)

          # Delete all existing RSVP posts
          all_rsvp_posts.each do |post|
            begin
              PostDestroyer.new(Discourse.system_user, post, context: "calendar-rsvp-posts cleanup").destroy
            rescue StandardError => e
              Rails.logger.warn("calendar-rsvp-posts: failed to delete post #{post.id}: #{e}")
            end
          end

          # Create new notification post
          notification_raw = build_notification_raw(username, action_label, event, extra_text)
          PostCreator.create!(
            Discourse.system_user,
            topic_id: event.post.topic_id,
            raw: notification_raw,
            skip_validations: true
          )
        end
      end
    end
  end

  # Background job: do the post writes off the request/callback path so the
  # synchronous RSVP status change doesn't race the calendar's avatar render
  # (the duplicate-avatar bug). Re-loads the event by id when it runs.
  module ::Jobs
    class ProcessCalendarRsvpPost < ::Jobs::Base
      def execute(args)
        event = DiscoursePostEvent::Event.find_by(id: args[:event_id])
        return unless event

        ::CalendarRsvpPosts.publish_rsvp_update(
          event,
          args[:username],
          args[:action_label],
          args[:extra_text]
        )
      end
    end
  end

  # Main handler for RSVP changes
  proc_handler = proc do |invitee|
    begin
      event = invitee&.event
      next if event.nil?
      next unless CalendarRsvpPosts.should_post_for_event?(event)

      going_val = DiscoursePostEvent::Invitee.statuses[:going]
      interested_val = DiscoursePostEvent::Invitee.statuses[:interested]
      not_going_val = DiscoursePostEvent::Invitee.statuses[:not_going]

      new_status = invitee.status
      prev_status =
        if invitee.respond_to?(:previous_changes) && invitee.previous_changes["status"]
          invitee.previous_changes["status"][0]
        else
          nil
        end

      # ignore if RSVP didn't change
      next if prev_status && prev_status == new_status

      username = invitee.user&.username || "someone"
      action_label = nil

      # Determine whether this qualifies as a "new" RSVP (create) or an update
      if new_status == going_val && SiteSetting.calendar_rsvp_posts_on_new_going
        action_label = I18n.t('calendar_rsvp_posts.actions.going')
      elsif new_status == interested_val && SiteSetting.calendar_rsvp_posts_on_new_interested
        action_label = I18n.t('calendar_rsvp_posts.actions.interested')
      elsif new_status == not_going_val && SiteSetting.calendar_rsvp_posts_on_new_not_going
        action_label = I18n.t('calendar_rsvp_posts.actions.not_going')
      end

      # Nothing configured for this change
      next if action_label.nil?

      # Compute capacity change texts if event has max_attendees
      extra_text = nil
      if event.max_attendees.present?
        # Compute previous and current going counts based on this single invitee change
        current_going = event.going_count
        prev_going =
          if prev_status == going_val && new_status != going_val
            current_going + 1
          elsif prev_status != going_val && new_status == going_val
            current_going - 1
          else
            current_going
          end

        was_full = prev_going >= event.max_attendees
        is_full = current_going >= event.max_attendees

        if was_full && !is_full
          extra_text = I18n.t('calendar_rsvp_posts.capacity.spots_available')
        elsif !was_full && is_full
          extra_text = I18n.t('calendar_rsvp_posts.capacity.now_full')
        end
      end

      # Hand the post writes to a background job instead of doing them inside the
      # invitee status-change callback (that raced the calendar avatar render).
      Jobs.enqueue(
        :process_calendar_rsvp_post,
        event_id: event.id,
        username: username,
        action_label: action_label,
        extra_text: extra_text
      )
    rescue StandardError => e
      Rails.logger.warn("calendar-rsvp-posts: handler error: #{e}")
      Rails.logger.warn(e.backtrace.join("\n"))
    end
  end

  # Handler for create/update attendance triggered by the calendar plugin
  on(:discourse_calendar_post_event_invitee_status_changed, &proc_handler)

  # Also handle explicit invitee deletions (removed RSVP)
  if defined?(DiscoursePostEvent::Invitee)
    DiscoursePostEvent::Invitee.class_eval do
      after_destroy do
        event = self.event
        # Skip if no event, not configured, or past event (when not allowed)
        should_process = event.present? &&
                         SiteSetting.calendar_rsvp_posts_on_removed_rsvp &&
                         (SiteSetting.calendar_rsvp_posts_allow_past_events || event.starts_at.nil? || event.starts_at >= Time.current)
        
        if should_process
          begin
            username = self.user&.username || "someone"
            action_label = I18n.t('calendar_rsvp_posts.actions.removed')

            # Hand off to the background job (see the create/update handler).
            Jobs.enqueue(
              :process_calendar_rsvp_post,
              event_id: event.id,
              username: username,
              action_label: action_label,
              extra_text: nil
            )
          rescue StandardError => e
            Rails.logger.warn("calendar-rsvp-posts: after_destroy handler error: #{e}")
            Rails.logger.warn(e.backtrace.join("\n"))
          end
        end
      end
    end
  end
end
