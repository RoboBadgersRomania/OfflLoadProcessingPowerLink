# ROS 2 Jazzy (LTS) + Gazebo Harmonic + Zenoh middleware + Foxglove bridge
FROM osrf/ros:jazzy-desktop-full

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ros-jazzy-rmw-zenoh-cpp \
        ros-jazzy-foxglove-bridge \
        python3-colcon-common-extensions \
        python3-pip git nano htop \
    && rm -rf /var/lib/apt/lists/*

# Zenoh works across the internet/Tailscale; default DDS needs multicast (doesn't work over Tailscale).
ENV RMW_IMPLEMENTATION=rmw_zenoh_cpp

RUN echo 'source /opt/ros/jazzy/setup.bash' >> /root/.bashrc \
 && echo '[ -f /ws/install/setup.bash ] && source /ws/install/setup.bash' >> /root/.bashrc

WORKDIR /ws
CMD ["bash"]
