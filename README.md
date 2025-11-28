discourse-calendar-rsvp-posts

Creates short topic replies for RSVP events (Going / Interested / Not going / Removed) according to site settings.

## How It Works

The plugin keeps RSVP activity visible while minimizing topic clutter:
- On the first RSVP, creates a simple notification post announcing the RSVP
- On the second RSVP, transforms the first post into a timestamped history post, then creates a new notification post
- On subsequent RSVPs, appends each RSVP to the history post with timestamp, deletes the previous notification post, and creates a new one

This ensures:
- **Real-time notifications** - Every RSVP triggers notifications for topic watchers
- **Minimal clutter** - Maximum of 2 posts at any time (1 history + 1 latest notification)
- **Complete history** - All RSVP activity is preserved with timestamps in chronological order
- **Discourages flip-flopping** - Timestamps make repeated RSVP changes visible

Install:
- Create a GitHub repo from this directory, clone into your Discourse `plugins/` and restart Discourse.

Site settings (in Admin > Settings > Plugins):
- `calendar_rsvp_posts_on_new_going`: post on new "Going"
- `calendar_rsvp_posts_on_new_interested`: post on new "Interested"
- `calendar_rsvp_posts_on_new_not_going`: post on new "Not going"
- `calendar_rsvp_posts_on_removed_rsvp`: post when an RSVP is removed
- `calendar_rsvp_posts_allow_past_events`: whether to post for events that start in the past
- `calendar_rsvp_posts_enable_history`: maintain a timestamped history post (default: enabled)
