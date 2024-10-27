const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Specify static or dynamic linkage",
    ) orelse .dynamic;

    // These are the only lazy dependencies so far, so if they aren't fetched, early exit
    const upstream = switch (linkage) {
        .static => b.lazyDependency("rclcpp", .{}) orelse return,
        .dynamic => b.lazyDependency("rclcpp_visibility_control", .{}) orelse return,
    };

    const dep_args = .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
    };

    const rcl_dep = b.dependency("rcl", dep_args);
    const rcpputils_dep = b.dependency("rcpputils", dep_args);
    const libstatistics_collector_dep = b.dependency("libstatistics_collector", dep_args);
    const ament_index_dep = b.dependency("ament_index", dep_args);

    // Grab dependency from rcl to avoid version miss matches
    const rosidl_dep = rcl_dep.builder.dependency("rosidl", dep_args);
    const rcl_logging_dep = rcl_dep.builder.dependency("rcl_logging", dep_args);
    const rcl_interfaces_dep = rcl_dep.builder.dependency("rcl_interfaces", dep_args);
    const rcutils_dep = rcl_dep.builder.dependency("rcutils", dep_args);
    const rmw_dep = rcl_dep.builder.dependency("rmw", dep_args);
    const ros2_tracing_dep = rcl_dep.builder.dependency("ros2_tracing", dep_args);

    const logger_command =
        \\import em
        \\import sys
        \\output = sys.argv[1]
        \\rcutils = sys.argv[2]
        \\sys.path.append(rcutils)
        \\em.invoke(['-o', output, 'resource/logging.hpp.em'])
    ;

    // TODO replace with zig built python? (would remove system dependencies)
    var logger_step = b.addSystemCommand(&.{ "python3", "-c", logger_command });
    logger_step.setCwd(upstream.path("rclcpp")); // for easy access to resource dir

    const logging_output = logger_step.addOutputFileArg("include/rclcpp/logging.hpp");
    logger_step.addDirectoryArg(rcutils_dep.namedWriteFiles("rcutils").getDirectory());

    var rclcpp = std.Build.Step.Compile.create(b, .{
        .root_module = .{
            .target = target,
            .optimize = optimize,
            .pic = if (linkage == .dynamic) true else null,
        },
        .name = "rclcpp",
        .kind = .lib,
        .linkage = linkage,
    });

    // Add the parent directory to be sure that the file structuree is captured
    rclcpp.addIncludePath(logging_output.dirname().dirname());
    rclcpp.installHeader(logging_output, "rclcpp/logging.hpp");

    rclcpp.step.dependOn(&logger_step.step);
    const interfaces = &.{
        "node_base_interface",
        "node_clock_interface",
        "node_graph_interface",
        "node_logging_interface",
        "node_parameters_interface",
        "node_services_interface",
        "node_time_source_interface",
        "node_timers_interface",
        "node_topics_interface",
        "node_type_descriptions_interface",
        "node_waitables_interface",
    };
    inline for (interfaces) |interface_name| {
        const interface_command_template =
            \\import em
            \\import sys
            \\output = sys.argv[1]
            \\rcutils = sys.argv[2]
            \\sys.path.append(rcutils)
            \\em.invoke(['-D', 'interface_name = \'{[interface_name]s}\'', 
            \\        '-o', output, 'resource/interface_traits.hpp.em'])
        ;
        const interface_output_template =
            "include/rclcpp/node_interfaces/{[interface_name]s}_traits.hpp";
        var buf: [512]u8 = undefined;
        const interface_command = std.fmt.bufPrint(
            &buf,
            interface_command_template,
            .{ .interface_name = interface_name },
        ) catch @panic("out of buffer space");

        // TODO replace with zig built python? (would remove system dependencies)
        var interface_step = b.addSystemCommand(&.{ "python3", "-c", interface_command });
        interface_step.setCwd(upstream.path("rclcpp")); // for easy access to resource

        // safe to use buf here again since addArgs duplicates the string
        const interface_output_arg = std.fmt.bufPrint(
            &buf,
            interface_output_template,
            .{ .interface_name = interface_name },
        ) catch @panic("out of buffer space");
        const interface_output = interface_step.addOutputFileArg(interface_output_arg);
        interface_step.addDirectoryArg(
            rcutils_dep.namedWriteFiles("rcutils").getDirectory(),
        );

        // Add the parent directory to be sure that the file structuree is captured
        rclcpp.addIncludePath(interface_output.dirname().dirname().dirname());
        rclcpp.installHeader(interface_output, std.mem.trimLeft(u8, interface_output_arg, "include/"));

        const get_command_template =
            \\import em
            \\import sys
            \\output = sys.argv[1]
            \\rcutils = sys.argv[2]
            \\sys.path.append(rcutils)
            \\em.invoke(['-D', 'interface_name = \'{[interface_name]s}\'', 
            \\        '-o', output, 'resource/get_interface.hpp.em'])
        ;
        const get_output_template = "include/rclcpp/node_interfaces/get_{[interface_name]s}.hpp";
        const get_command = std.fmt.bufPrint(
            &buf,
            get_command_template,
            .{ .interface_name = interface_name },
        ) catch @panic("out of buffer space");

        // TODO replace with zig built python? (would remove system dependencies)
        var get_step = b.addSystemCommand(&.{ "python3", "-c", get_command });
        get_step.setCwd(upstream.path("rclcpp")); // for easy access to resource

        // safe to use buf here again since addArgs duplicates the string
        const get_output_arg = std.fmt.bufPrint(
            &buf,
            get_output_template,
            .{ .interface_name = interface_name },
        ) catch @panic("out of buffer space");
        const get_output = get_step.addOutputFileArg(get_output_arg);
        get_step.addDirectoryArg(
            rcutils_dep.namedWriteFiles("rcutils").getDirectory(),
        );

        // Add the parent directory to be sure that the file structuree is captured
        rclcpp.addIncludePath(get_output.dirname().dirname().dirname());
        rclcpp.installHeader(get_output, std.mem.trimLeft(u8, get_output_arg, "include/"));
    }

    rclcpp.linkLibrary(rcl_dep.artifact("rcl"));
    rclcpp.linkLibrary(rcl_dep.artifact("rcl_yaml_param_parser"));
    rclcpp.linkLibrary(rcl_logging_dep.artifact("rcl_logging_interface"));

    rclcpp.linkLibrary(rcl_interfaces_dep
        .artifact("type_description_interfaces__rosidl_generator_c"));
    rclcpp.linkLibrary(rcl_interfaces_dep.artifact("service_msgs__rosidl_generator_c"));
    rclcpp.linkLibrary(rcl_interfaces_dep.artifact("builtin_interfaces__rosidl_generator_c"));

    rclcpp.linkLibrary(rcutils_dep.artifact("rcutils"));
    rclcpp.linkLibrary(rcpputils_dep.artifact("rcpputils"));
    rclcpp.linkLibrary(rmw_dep.artifact("rmw"));
    rclcpp.linkLibrary(rosidl_dep.artifact("rosidl_dynamic_typesupport"));
    rclcpp.linkLibrary(rosidl_dep.artifact("rosidl_runtime_c"));
    rclcpp.addIncludePath(rosidl_dep
        .namedWriteFiles("rosidl_typesupport_interface").getDirectory());
    rclcpp.linkLibrary(libstatistics_collector_dep.artifact("libstatistics_collector"));
    rclcpp.linkLibrary(ament_index_dep.artifact("ament_index_cpp"));
    rclcpp.addIncludePath(ros2_tracing_dep.namedWriteFiles("tracetools").getDirectory());

    rclcpp.addIncludePath(upstream.path("rclcpp/include"));
    rclcpp.installHeadersDirectory(
        upstream.path("rclcpp/include"),
        "",
        .{ .include_extensions = &.{ ".h", ".hpp" } },
    );

    rclcpp.addIncludePath(rosidl_dep.namedWriteFiles("rosidl_runtime_cpp").getDirectory());
    rclcpp.linkLibrary(rosidl_dep.artifact("rosidl_typesupport_introspection_cpp"));
    rclcpp.addIncludePath(rcl_interfaces_dep
        .namedWriteFiles("builtin_interfaces__rosidl_generator_cpp").getDirectory());
    rclcpp.addIncludePath(rcl_interfaces_dep
        .namedWriteFiles("rcl_interfaces__rosidl_generator_cpp").getDirectory());
    rclcpp.addIncludePath(rcl_interfaces_dep
        .namedWriteFiles("service_msgs__rosidl_generator_cpp").getDirectory());
    rclcpp.addIncludePath(rcl_interfaces_dep
        .namedWriteFiles("statistics_msgs__rosidl_generator_cpp").getDirectory());
    rclcpp.addIncludePath(rcl_interfaces_dep
        .namedWriteFiles("rosgraph_msgs__rosidl_generator_cpp").getDirectory());

    rclcpp.addCSourceFiles(.{
        .root = upstream.path("rclcpp/src/rclcpp"),
        .files = &.{
            "any_executable.cpp",
            "callback_group.cpp",
            "client.cpp",
            "clock.cpp",
            "context.cpp",
            "contexts/default_context.cpp",
            "create_generic_client.cpp",
            "detail/add_guard_condition_to_rcl_wait_set.cpp",
            "detail/resolve_intra_process_buffer_type.cpp",
            "detail/resolve_parameter_overrides.cpp",
            "detail/rmw_implementation_specific_payload.cpp",
            "detail/rmw_implementation_specific_publisher_payload.cpp",
            "detail/rmw_implementation_specific_subscription_payload.cpp",
            "detail/utilities.cpp",
            "duration.cpp",
            "dynamic_typesupport/dynamic_message.cpp",
            "dynamic_typesupport/dynamic_message_type.cpp",
            "dynamic_typesupport/dynamic_message_type_builder.cpp",
            "dynamic_typesupport/dynamic_message_type_support.cpp",
            "dynamic_typesupport/dynamic_serialization_support.cpp",
            "event.cpp",
            "exceptions/exceptions.cpp",
            "executable_list.cpp",
            "executor.cpp",
            "executor_options.cpp",
            "executors.cpp",
            "executors/executor_entities_collection.cpp",
            "executors/executor_entities_collector.cpp",
            "executors/executor_notify_waitable.cpp",
            "executors/multi_threaded_executor.cpp",
            "executors/single_threaded_executor.cpp",
            "executors/static_single_threaded_executor.cpp",
            "expand_topic_or_service_name.cpp",
            "experimental/executors/events_executor/events_executor.cpp",
            "experimental/timers_manager.cpp",
            "future_return_code.cpp",
            "generic_client.cpp",
            "generic_publisher.cpp",
            "generic_subscription.cpp",
            "graph_listener.cpp",
            "guard_condition.cpp",
            "init_options.cpp",
            "intra_process_manager.cpp",
            "logger.cpp",
            "logging_mutex.cpp",
            "memory_strategies.cpp",
            "memory_strategy.cpp",
            "message_info.cpp",
            "network_flow_endpoint.cpp",
            "node.cpp",
            "node_interfaces/node_base.cpp",
            "node_interfaces/node_clock.cpp",
            "node_interfaces/node_graph.cpp",
            "node_interfaces/node_logging.cpp",
            "node_interfaces/node_parameters.cpp",
            "node_interfaces/node_services.cpp",
            "node_interfaces/node_time_source.cpp",
            "node_interfaces/node_timers.cpp",
            "node_interfaces/node_topics.cpp",
            "node_interfaces/node_type_descriptions.cpp",
            "node_interfaces/node_waitables.cpp",
            "node_options.cpp",
            "parameter.cpp",
            "parameter_client.cpp",
            "parameter_event_handler.cpp",
            "parameter_events_filter.cpp",
            "parameter_map.cpp",
            "parameter_service.cpp",
            "parameter_value.cpp",
            "publisher_base.cpp",
            "qos.cpp",
            "event_handler.cpp",
            "qos_overriding_options.cpp",
            "rate.cpp",
            "serialization.cpp",
            "serialized_message.cpp",
            "service.cpp",
            "signal_handler.cpp",
            "subscription_base.cpp",
            "subscription_intra_process_base.cpp",
            "time.cpp",
            "time_source.cpp",
            "timer.cpp",
            "type_support.cpp",
            "typesupport_helpers.cpp",
            "utilities.cpp",
            "wait_set_policies/detail/write_preferring_read_write_lock.cpp",
            "waitable.cpp",
        },
        .flags = &.{
            "-DROS_PACKAGE_NAME=\"rclcpp\"",
            "-DRCLCPP_BUILDING_LIBRARY",
            "--std=c++17",
            "-Wno-deprecated-declarations",
            "-fvisibility=hidden",
            "-fvisibility-inlines-hidden",
        },
    });
    b.installArtifact(rclcpp);
}
