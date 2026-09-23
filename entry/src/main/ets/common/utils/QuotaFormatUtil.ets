/** 套餐额度使用 1024 进制，最多保留两位小数并移除无意义的末尾 0。 */
export function formatQuotaBytes(bytes: number): string {
  const safeBytes = Number.isFinite(bytes) && bytes > 0 ? bytes : 0
  let show = safeBytes
  let unit = 'B'
  if (safeBytes >= Math.pow(1024, 4)) {
    show = safeBytes / Math.pow(1024, 4)
    unit = 'TB'
  } else if (safeBytes >= Math.pow(1024, 3)) {
    show = safeBytes / Math.pow(1024, 3)
    unit = 'GB'
  } else if (safeBytes >= Math.pow(1024, 2)) {
    show = safeBytes / Math.pow(1024, 2)
    unit = 'MB'
  } else if (safeBytes >= Math.pow(1024, 1)) {
    show = safeBytes / Math.pow(1024, 1)
    unit = 'KB'
  }
  const precise = show.toFixed(2).replace(/\.00$/, '').replace(/(\.\d)0$/, '$1')
  return `${precise} ${unit}`
}
