discourse-calendar-rsvp-posts

Creates short topic replies for RSVP events (Going / Interested / Not going / Removed) according to site settings.

Install:
- Create a GitHub repo from this directory, clone into your Discourse `plugins/` and restart Discourse.

Site settings (in Admin > Settings > Plugins):
- `calendar_rsvp_posts_on_new_going`: post on new "Going"
- `calendar_rsvp_posts_on_new_interested`: post on new "Interested"
- `calendar_rsvp_posts_on_new_not_going`: post on new "Not going"
- `calendar_rsvp_posts_on_removed_rsvp`: post when an RSVP is removed
- `calendar_rsvp_posts_allow_past_events`: whether to post for events that start in the past
