package com.notel.notel.data.repository

import com.notel.notel.data.local.dao.CategoryDao
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.sync.SyncManager
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class CategoryRepository @Inject constructor(
    private val categoryDao: CategoryDao,
    private val syncManager: SyncManager
) {
    fun getAllCategories(): Flow<List<Category>> = categoryDao.getAllCategories()

    suspend fun insertCategory(category: Category) {
        categoryDao.insertCategory(category)
        triggerSync()
    }

    suspend fun updateCategory(category: Category) {
        categoryDao.updateCategory(category)
        triggerSync()
    }

    suspend fun deleteCategory(category: Category) {
        categoryDao.deleteCategory(category)
        syncManager.deleteCategoryRemote(category.id)
    }

    suspend fun clearCustomCategories() {
        categoryDao.clearCustomCategories()
        triggerSync()
    }

    suspend fun getMaxCategoryId(): Int = categoryDao.getMaxCategoryId() ?: 0

    suspend fun insertAll(categories: List<Category>) {
        categoryDao.insertAll(categories)
        triggerSync()
    }
    
    @OptIn(DelicateCoroutinesApi::class)
    private fun triggerSync() {
        GlobalScope.launch {
            syncManager.syncAllData()
        }
    }
}
