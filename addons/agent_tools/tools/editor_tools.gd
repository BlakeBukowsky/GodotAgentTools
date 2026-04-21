@tool
extends RefCounted

# editor.reload_filesystem — trigger an editor filesystem rescan.
# Run this after external file changes (created/moved/deleted by tools outside the editor)
# so load() and the FileSystem dock reflect reality.
static func reload_filesystem(_params: Dictionary) -> Dictionary:
	EditorInterface.get_resource_filesystem().scan()
	return {"data": {"scanned": true}}


# editor.save_all_scenes — save every open edited scene.
static func save_all_scenes(_params: Dictionary) -> Dictionary:
	EditorInterface.save_all_scenes()
	return {"data": {"saved": true}}
