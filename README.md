Axle is an under-development init system just like any other init system. It aims to be highly configurable and dynamic.  
Making it because systemd sucks, and others are too minimal.

---

### TODO:
- [x] **PID 1 behavior** (Half done, needs improvement)  
- [x] **Service management** (start, stop, supervise)  
- [ ] **Config parsing**  
- [ ] **Dependency handling**  
- [x] **Signal handling** (SIGCHLD, SIGTERM)  
- [x] **Graceful shutdown**  
- [x] **Service supervision** (auto-restart)  
- [x] **Logging**  
- [ ] **Runlevels/targets**  
- [ ] **Event-based service startup**  
- [x] **Service state tracking**  
- [ ] **CLI tool for managing services**  
- [ ] **Socket activation**  
- [ ] **Parallelization**  
- [ ] **Resource limits** (memory, CPU)  
- [ ] **Reload configuration dynamically**  
- [ ] **Hotplug handling**  
- [ ] **Health checks**  
- [ ] **Debugging tools**  
- [ ] **Service isolation**

## TODO PID 1:
- [x] Reaping Zombie Processes
- [ ] Handling Orphaned Processes
- [ ] Signal Mask Setup
- [ ] Service Dependency Management
- [X] Add watchdog
- [X] Exit Behavior
- [ ] File Descriptor Management

---

#### Copyright (C) 2025 rudy-in

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,  
but WITHOUT ANY WARRANTY; without even the implied warranty of  
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the  
GNU General Public License for more details.

You should have received a copy of the GNU General Public License  
along with this program. If not, see <https://www.gnu.org/licenses/>.

