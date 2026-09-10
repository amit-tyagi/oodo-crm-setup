FROM odoo:18

USER root

# Install any additional system dependencies here if needed
# RUN apt-get update && apt-get install -y <package> && rm -rf /var/lib/apt/lists/*

# Copy custom addons (uncomment when you have them)
# COPY ./addons /mnt/extra-addons

# Copy custom odoo.conf (uncomment to override defaults)
# COPY ./config/odoo.conf /etc/odoo/odoo.conf

USER odoo
