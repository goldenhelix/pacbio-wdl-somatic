mkdir -p "${WORKSPACE_DIR}/AppData/VarSeq/User Data/ProjectTemplates"

cp -f ./.project_templates/*.vsproject-template "${WORKSPACE_DIR}/AppData/VarSeq/User Data/ProjectTemplates"

echo "Installed VarSeq project templates"