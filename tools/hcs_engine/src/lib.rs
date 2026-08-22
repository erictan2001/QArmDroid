//! Arm64Droid native HCS + Vulkan passthrough host library.
//!
//! The library exposes the pieces both the daemon binary and the
//! integration tests link against:
//!   * `vulkan_host` — loads vulkan-1.dll, probes the host GPU, creates a
//!     logical device + queue, and keeps a dispatch table.
//!   * `dispatch`   — executes guest opcodes against the host engine.
//!   * `hcs`        — probes the Microsoft Host Compute System client DLL.
//!   * `shm_ring`   — the legacy shared-memory aperture ring simulation.

pub mod dispatch;
pub mod hcs;
pub mod render;
pub mod shm_ring;
pub mod vulkan_host;

#[cfg(test)]
mod dispatch_tests;