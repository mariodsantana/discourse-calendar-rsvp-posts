# frozen_string_literal: true
# name: discourse-calendar-rsvp-posts
# about: Create short topic replies for RSVP events
# version: 0.1
# authors: Mario Santana

after_initialize do
  module ::CalendarRsvpPosts
    PLUGIN_NAME = "discourse-calendar-rsvp-posts"
  end

  # Helper to decide if we should ignore this event
  def should_post_for_event?(event)
    return false if event.nil?
    return true if SiteSetting.calendar_rsvp_posts_allow_past_events
    return false if event.starts_at.nil?
    event.starts_at >= Time.current
  end

  # Build a small raw post for the topic
  def build_rsvp_raw(username, action_label, event, extra_text = nil)
    event_title = (event.name.presence || event.post.topic.title).to_s
    parts = []
    parts << "**#{username} #{action_label}** for *#{event_title}*."
    parts << extra_text if extra_text.present?
    parts.join(" ")
  end

  proc_handler = proc do |invitee|
    begin
      event = invitee&.event
      next if event.nil?
      next unless should_post_for_event?(event)

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
      next if prev_status && prev_status != new_status

      username = invitee.user&.username || "someone"
      action_label = nil

      # Determine whether this qualifies as a "new" RSVP (create) or an update
      if new_status == going_val && SiteSetting.calendar_rsvp_posts_on_new_going
        action_label = "is going"
      elsif new_status == interested_val && SiteSetting.calendar_rsvp_posts_on_new_interested
        action_label = "is interested"
      elsif new_status == not_going_val && SiteSetting.calendar_rsvp_posts_on_new_not_going
        action_label = "is not going"
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
          extra_text = "Spots now available."
        elsif !was_full && is_full
          extra_text = "Now full."
        end
      end

      raw = build_rsvp_raw(username, action_label, event, extra_text)

      # Create a short system post in the topic
      PostCreator.create!(
        Discourse.system_user,
        topic_id: event.post.topic_id,
        raw: raw,
        skip_validations: true
      )
    rescue StandardError => e
      Rails.logger.warn("calendar-rsvp-posts: handler error: #{e}")
    end
  end

  # Handler for create/update attendance triggered by the calendar plugin
  on(:discourse_calendar_post_event_invitee_status_changed, &proc_handler)

  # Also handle explicit invitee deletions (removed RSVP)
  if defined?(DiscoursePostEvent::Invitee)
    DiscoursePostEvent::Invitee.class_eval do
      after_destroy do
        begin
          event = self.event
          next if event.nil?

          # post for removed RSVP only if configured
          next unless SiteSetting.calendar_rsvp_posts_on_removed_rsvp
          # respect past-event setting
          next if !SiteSetting.calendar_rsvp_posts_allow_past_events && event.starts_at.present? && event.starts_at < Time.current

          username = self.user&.username || "someone"
          action_label = "removed their RSVP"

          raw = "**#{username} #{action_label}** for *#{event.name.presence || event.post.topic.title}*."

          PostCreator.create!(
            Discourse.system_user,
            topic_id: event.post.topic_id,
            raw: raw,
            skip_validations: true
          )
        rescue StandardError => e
          Rails.logger.warn("calendar-rsvp-posts: after_destroy handler error: #{e}")
        end
      end
    end
  end
end
