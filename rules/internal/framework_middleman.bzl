load("@bazel_skylib//lib:partial.bzl", "partial")
load(
    "@build_bazel_rules_apple//apple:providers.bzl",
    "AppleBundleInfo",
    "AppleResourceInfo",
    "IosFrameworkBundleInfo",
)
load(
    "@build_bazel_rules_apple//apple/internal:partials.bzl",
    "partials",
)
load(
    "@build_bazel_rules_apple//apple/internal:resources.bzl",
    "resources",
)
load(
    "//rules:providers.bzl",
    "AvoidDepsInfo",
)
load(
    "@build_bazel_rules_apple//apple/internal/providers:embeddable_info.bzl",
    "AppleEmbeddableInfo",
    "embeddable_info",
)
load(
    "//rules/internal:objc_provider_utils.bzl",
    "objc_provider_utils",
)

def _framework_middleman(ctx):
    resource_providers = []
    objc_providers = []
    dynamic_framework_providers = []
    apple_embeddable_infos = []
    cc_providers = []

    def _collect_providers(lib_dep):
        if AppleEmbeddableInfo in lib_dep:
            apple_embeddable_infos.append(lib_dep[AppleEmbeddableInfo])

        # Most of these providers will be passed into `deps` of apple rules.
        # Don't feed them twice. There are several assumptions rules_apple on
        # this
        if IosFrameworkBundleInfo in lib_dep:
            if CcInfo in lib_dep:
                cc_providers.append(lib_dep[CcInfo])
            if AppleResourceInfo in lib_dep:
                resource_providers.append(lib_dep[AppleResourceInfo])
        if apple_common.Objc in lib_dep:
            objc_providers.append(lib_dep[apple_common.Objc])
        if apple_common.AppleDynamicFramework in lib_dep:
            dynamic_framework_providers.append(lib_dep[apple_common.AppleDynamicFramework])

    for dep in ctx.attr.framework_deps:
        _collect_providers(dep)

        # Loop AvoidDepsInfo here as well
        if AvoidDepsInfo in dep:
            for lib_dep in dep[AvoidDepsInfo].libraries:
                _collect_providers(lib_dep)

    # Here we only need to loop a subset of the keys
    objc_provider_fields = objc_provider_utils.merge_objc_providers_dict(providers = objc_providers, merge_keys = [
        "dynamic_framework_file",
    ])

    # Add the frameworks to the linker command
    dynamic_framework_provider = objc_provider_utils.merge_dynamic_framework_providers(ctx, dynamic_framework_providers)
    objc_provider_fields["dynamic_framework_file"] = depset(
        transitive = [dynamic_framework_provider.framework_files, objc_provider_fields.get("dynamic_framework_file", depset([]))],
    )
    objc_provider = apple_common.new_objc_provider(**objc_provider_fields)
    cc_info_provider = cc_common.merge_cc_infos(direct_cc_infos = [], cc_infos = cc_providers)
    providers = [
        dynamic_framework_provider,
        cc_info_provider,
        objc_provider,
        IosFrameworkBundleInfo(),
        AppleBundleInfo(
            archive = None,
            archive_root = None,
            binary = None,

            # These arguments are unused - however, put them here incase that
            # somehow changes to make it easier to debug
            bundle_id = "com.bazel_build_rules_ios.unused",
            bundle_name = "bazel_build_rules_ios_unused",
        ),
    ]

    embed_info_provider = embeddable_info.merge_providers(apple_embeddable_infos)
    if embed_info_provider:
        providers.append(embed_info_provider)

    if len(resource_providers) > 0:
        resource_provider = resources.merge_providers(
            default_owner = str(ctx.label),
            providers = resource_providers,
        )
        providers.append(resource_provider)

    # Just to populate the extension safety provider from `rules_apple`.
    partial_output = partial.call(
        partials.extension_safe_validation_partial(
            is_extension_safe = ctx.attr.extension_safe,
            rule_label = ctx.label,
            # Pass 'ctx.attr.framework_deps' once 'partials.extension_safe_validation_partial'
            # is populated on from 'apple_framework_packaging' implementation.
            targets_to_validate = ctx.attr.framework_deps,
        ),
    )

    return providers + partial_output.providers

framework_middleman = rule(
    implementation = _framework_middleman,
    attrs = {
        "framework_deps": attr.label_list(
            cfg = apple_common.multi_arch_split,
            mandatory = True,
            doc =
                """Deps that may contain frameworks
""",
        ),
        "extension_safe": attr.bool(
            default = False,
            doc = """Internal - allow rules_apple to populate extension safe provider
""",
        ),
        "platform_type": attr.string(
            mandatory = False,
            doc =
                """Internal - currently rules_ios uses the dict `platforms`
""",
        ),
        "minimum_os_version": attr.string(
            mandatory = False,
            doc =
                """Internal - currently rules_ios the dict `platforms`
""",
        ),
    },
    doc = """
        This is a volatile internal rule to make frameworks work with
        rules_apples bundling logic

        Longer term, we will likely get rid of this and call partial like
        apple_framework directly so consider it an implementation detail
        """,
)

def _dedupe_key(key, avoid_libraries, objc_provider_fields, check_name = False):
    updated_library = []
    exisiting_library = objc_provider_fields.get(key, depset([]))
    for f in exisiting_library.to_list():
        check_key = (f.basename if check_name else f)
        if check_key in avoid_libraries:
            continue
        updated_library.append(f)
    objc_provider_fields[key] = depset(updated_library)

def _dep_middleman(ctx):
    objc_providers = []
    cc_providers = []
    avoid_libraries = {}

    def _collect_providers(lib_dep):
        if apple_common.Objc in lib_dep:
            objc_providers.append(lib_dep[apple_common.Objc])

    def _process_avoid_deps(avoid_dep_libs):
        for dep in avoid_dep_libs:
            if apple_common.Objc in dep:
                for lib in dep[apple_common.Objc].library.to_list():
                    avoid_libraries[lib] = True
                for lib in dep[apple_common.Objc].force_load_library.to_list():
                    avoid_libraries[lib] = True
                for lib in dep[apple_common.Objc].imported_library.to_list():
                    avoid_libraries[lib.basename] = True
                for lib in dep[apple_common.Objc].static_framework_file.to_list():
                    avoid_libraries[lib.basename] = True

    for dep in ctx.attr.deps:
        _collect_providers(dep)

        # Loop AvoidDepsInfo here as well
        if AvoidDepsInfo in dep:
            _process_avoid_deps(dep[AvoidDepsInfo].libraries)
            for lib_dep in dep[AvoidDepsInfo].libraries:
                _collect_providers(lib_dep)

    # Pull AvoidDeps from test deps
    for dep in (ctx.attr.test_deps if ctx.attr.test_deps else []):
        if AvoidDepsInfo in dep:
            _process_avoid_deps(dep[AvoidDepsInfo].libraries)

    # Merge the entire provider here
    objc_provider_fields = objc_provider_utils.merge_objc_providers_dict(providers = objc_providers, merge_keys = [
        "force_load_library",
        "imported_library",
        "library",
        "link_inputs",
        "linkopt",
        "sdk_dylib",
        "sdk_framework",
        "source",
        "static_framework_file",
        "weak_sdk_framework",
    ])

    # Ensure to strip out static link inputs
    _dedupe_key("library", avoid_libraries, objc_provider_fields)
    _dedupe_key("force_load_library", avoid_libraries, objc_provider_fields)
    _dedupe_key("imported_library", avoid_libraries, objc_provider_fields, check_name = True)
    _dedupe_key("static_framework_file", avoid_libraries, objc_provider_fields, check_name = True)

    objc_provider = apple_common.new_objc_provider(**objc_provider_fields)
    cc_info_provider = cc_common.merge_cc_infos(direct_cc_infos = [], cc_infos = cc_providers)
    providers = [
        cc_info_provider,
        objc_provider,
    ]
    return providers

dep_middleman = rule(
    implementation = _dep_middleman,
    attrs = {
        "deps": attr.label_list(
            cfg = apple_common.multi_arch_split,
            mandatory = True,
            doc =
                """Deps that may contain frameworks
""",
        ),
        "test_deps": attr.label_list(
            cfg = apple_common.multi_arch_split,
            allow_empty = True,
        ),
        "platform_type": attr.string(
            mandatory = False,
            doc =
                """Internal - currently rules_ios uses the dict `platforms`
""",
        ),
        "minimum_os_version": attr.string(
            mandatory = False,
            doc =
                """Internal - currently rules_ios the dict `platforms`
""",
        ),
    },
    doc = """
        This is a volatile internal rule to make frameworks work with
        rules_apples bundling logic

        Longer term, we will likely get rid of this and call partial like
        apple_framework directly so consider it an implementation detail
        """,
)
