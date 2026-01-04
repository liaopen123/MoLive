import Foundation
import CoreData

class ConversionRecordManager {
    static let shared = ConversionRecordManager()
    
    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "ConversionRecord")
        container.loadPersistentStores { description, error in
            if let error = error {
                fatalError("CoreData 加载失败: \(error.localizedDescription)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        return container
    }()
    
    var viewContext: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    private init() {}
    
    // 保存上下文
    func saveContext() {
        let context = viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                print("保存 CoreData 上下文失败: \(error.localizedDescription)")
            }
        }
    }
    
    // 检查是否已转换
    func isConverted(localIdentifier: String) -> Bool {
        let context = viewContext
        let request: NSFetchRequest<ConversionRecord> = ConversionRecord.fetchRequest()
        request.predicate = NSPredicate(format: "localIdentifier == %@", localIdentifier)
        request.fetchLimit = 1
        
        do {
            let count = try context.count(for: request)
            return count > 0
        } catch {
            print("查询转换记录失败: \(error.localizedDescription)")
            return false
        }
    }
    
    // 标记为已转换
    func markAsConverted(localIdentifier: String, date: Date = Date()) {
        let context = viewContext
        
        // 检查是否已存在
        if isConverted(localIdentifier: localIdentifier) {
            return
        }
        
        let record = ConversionRecord(context: context)
        record.localIdentifier = localIdentifier
        record.convertedDate = date
        
        saveContext()
    }
    
    // 批量标记为已转换
    func markAsConverted(localIdentifiers: [String], date: Date = Date()) {
        let context = viewContext
        
        for identifier in localIdentifiers {
            // 检查是否已存在
            if isConverted(localIdentifier: identifier) {
                continue
            }
            
            let record = ConversionRecord(context: context)
            record.localIdentifier = identifier
            record.convertedDate = date
        }
        
        saveContext()
    }
    
    // 获取已转换数量
    func getConvertedCount() -> Int {
        let context = viewContext
        let request: NSFetchRequest<ConversionRecord> = ConversionRecord.fetchRequest()
        
        do {
            return try context.count(for: request)
        } catch {
            print("获取转换记录数量失败: \(error.localizedDescription)")
            return 0
        }
    }
    
    // 获取所有已转换的标识符
    func getAllConvertedIdentifiers() -> Set<String> {
        let context = viewContext
        let request: NSFetchRequest<ConversionRecord> = ConversionRecord.fetchRequest()
        request.propertiesToFetch = ["localIdentifier"]
        
        do {
            let records = try context.fetch(request)
            return Set(records.compactMap { $0.localIdentifier })
        } catch {
            print("获取所有转换记录失败: \(error.localizedDescription)")
            return []
        }
    }
    
    // 清空所有记录
    func clearAllRecords() {
        let context = viewContext
        let request: NSFetchRequest<NSFetchRequestResult> = ConversionRecord.fetchRequest()
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        
        do {
            try context.execute(deleteRequest)
            saveContext()
        } catch {
            print("清空转换记录失败: \(error.localizedDescription)")
        }
    }
}

