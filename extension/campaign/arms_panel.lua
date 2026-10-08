function refreshStatus()
  local st=ArmsBridge.status()
  status_text.setValue("Modo: "..tostring(st.effectiveMode).." · Ataques pendientes: "..tostring(st.pendingCount or 0)..
    (st.ready and " · Integración disponible" or " · Consulta el diagnóstico antes de activar"))
end
function importCSV()
  local ok,err=ArmsCommands.importCSV(csv_input.getValue())
  if ok then csv_input.setValue(""); refreshStatus()
  else status_text.setValue("No se ha importado: "..tostring(err)) end
end
function onInit()
  refreshStatus()
  if not ArmsData.isHost() then
    mode_compare.setEnabled(false); mode_on.setEnabled(false); mode_off.setEnabled(false)
    import_button.setEnabled(false); csv_input.setReadOnly(true)
  end
end
